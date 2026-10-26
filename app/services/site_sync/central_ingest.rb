# frozen_string_literal: true

require 'set'

module SiteSync
  # Applies one batch from a site at central.
  #
  # Order of checks (design section 5):
  #   1. site signature (controller) and batch hash
  #   2. server generation and batch-number continuity / hash chain
  #   3. schema version, clock
  #   4. field types and required values
  #   5. ownership
  #   6. referenced records exist
  #   7. clinical sanity checks
  #
  # Checks 1-3 refuse the whole batch. Checks 4-7 quarantine single events:
  # the events that depend on them, or were saved by the same API request, are
  # parked with them, and the rest of the batch is applied. The whole batch is
  # applied in one transaction and acknowledged only after it commits.
  class CentralIngest
    GENESIS = '0' * 64
    Result = Struct.new(:status, :body)

    def initialize(site_code)
      @site_code = site_code
      @conn = ActiveRecord::Base.lease_connection
      @codec = Codec.new(@conn)
      @store = RowStore.new(@conn)
      @reference_ids = {}
    end

    def call(batch)
      header = batch.fetch('header')
      events_json = batch.fetch('events_json')

      return refuse(400, 'site_mismatch') unless header['site'] == @site_code

      computed = Digest::SHA256.hexdigest("#{header['previous_batch_hash']}#{events_json}")
      unless computed == header['batch_hash']
        Central.alert(@site_code, 'batch_tampered',
                      "Batch #{header['priority']}##{header['batch_number']} does not match its own hash: changed after sealing")
        return refuse(400, 'batch_hash_mismatch')
      end

      supported = [Config.schema_version, Config.schema_version - 1]
      return refuse(426, 'schema_version_unsupported', supported:) unless supported.include?(header['schema_version'])

      Central.with_feed_lock { ingest(header, events_json) }
    end

    # A data officer releases a quarantined record after fixing its cause.
    # It is applied as it stands (the officer has judged it), followed by the
    # records parked behind it: its dependants and the rest of its request.
    def release(item)
      Central.with_feed_lock do
        @conn.transaction { apply_parked([item], status: 'released') }
      end
    end

    private

    # Apply quarantined items in order, then whatever was parked behind each
    # one that succeeds (its dependants and the rest of its API request).
    def apply_parked(queue, status:)
      results = []
      seen = Set.new
      until queue.empty?
        current = queue.shift
        next unless seen.add?(current['id'])

        event = JSON.parse(current['change_json'])
        begin
          @conn.transaction(requires_new: true) { apply(event) }
          @conn.execute(<<~SQL)
            UPDATE sync_quarantine SET status = #{q(status)}, resolved_at = NOW(6) WHERE id = #{current['id'].to_i}
          SQL
          results << { 'id' => current['id'], 'uuid' => event['uuid'], 'status' => 'applied' }
          queue.concat(parked_behind(event['uuid'], [current['request_id']].compact, only_parked: false))
        rescue Codec::MissingRef, ActiveRecord::StatementInvalid => e
          results << { 'id' => current['id'], 'uuid' => event['uuid'], 'status' => 'still_blocked',
                       'error' => e.message.slice(0, 300) }
        end
      end
      results
    end

    # Open items waiting on `uuid`. With only_parked, only records held back
    # because of it are retried; records with a problem of their own stay for
    # the site or a data officer.
    def parked_behind(uuid, request_ids, only_parked:)
      reasons = only_parked ? "AND reason IN ('parent_quarantined', 'request_parked', 'missing_reference')" : ''
      siblings = request_ids.any? ? "OR request_id IN (#{request_ids.map { |r| q(r) }.join(', ')})" : ''
      @conn.select_all(<<~SQL).to_a
        SELECT * FROM sync_quarantine
        WHERE site_code = #{q(@site_code)} AND status = 'open' #{reasons}
          AND (waiting_for_uuid = #{q(uuid)} #{siblings})
        ORDER BY id
      SQL
    end

    def ingest(header, events_json)
      site = Central.site(@site_code)
      if header['server_generation'].to_i != site['server_generation'].to_i
        Central.alert(@site_code, 'stale_epoch',
                      "Refused batch from server generation #{header['server_generation']}; current server generation is #{site['server_generation']}. " \
                      'An old or cloned server may be running.')
        return refuse(409, 'stale_epoch', current_epoch: site['server_generation'].to_i)
      end
      return refuse(423, 'site_not_active', status: site['status']) unless site['status'] == 'active'

      priority = lane_state(header['server_generation'], header['priority'])
      batch_number = header['batch_number'].to_i

      if batch_number <= priority[:last_batch_number]
        stored = @conn.select_one(<<~SQL)
          SELECT batch_hash, central_reply_json FROM sync_received_batches
          WHERE site_code = #{q(@site_code)} AND server_generation = #{header['server_generation'].to_i}
            AND priority = #{q(header['priority'])} AND batch_number = #{batch_number}
        SQL
        return Result.new(200, JSON.parse(stored['central_reply_json']).merge('duplicate' => true)) if stored && stored['batch_hash'] == header['batch_hash']

        return refuse(409, 'batch_hash_conflict', expected_seq: priority[:last_batch_number] + 1)
      end
      return refuse(409, 'sequence_gap', expected_seq: priority[:last_batch_number] + 1) if batch_number != priority[:last_batch_number] + 1

      unless header['previous_batch_hash'] == priority[:last_batch_hash]
        Central.alert(@site_code, 'chain_broken', "Batch #{header['priority']}##{batch_number} does not chain to the last accepted batch")
        return refuse(409, 'chain_broken', expected_seq: priority[:last_batch_number] + 1)
      end

      events = JSON.parse(events_json)
      # A site whose clock ran ahead (a dead BIOS battery, a typo) must not
      # win every conflict, but refusing its batches would block it for as
      # long as the clock was wrong. Cap such clocks at central's time; the
      # capped events cannot win a conflict automatically (resolve_fields).
      central_now = Hlc.now_us
      limit = central_now + Config.max_clock_ahead_us
      clamped = events.count { |e| e['change_time'].to_i > limit }
      if clamped.positive?
        events.each do |e|
          next unless e['change_time'].to_i > limit

          e['site_change_time'] = e['change_time']
          # Central's real time, not time + margin: a field version stamped
          # ahead would make genuine edits from other sites lose for minutes.
          e['change_time'] = central_now
          e['clock_clamped'] = true
        end
        Central.alert(@site_code, 'clock_ahead',
                      "#{clamped} change(s) stamped more than #{Config.max_clock_ahead_us / 1_000_000}s ahead of central; " \
                      'capped at central time. Check the site server clock.')
      end

      ack = nil
      @conn.transaction do
        outcome = apply_events(events)
        ack = {
          'status' => 'ok', 'priority' => header['priority'], 'last_batch_number' => batch_number, 'batch_hash' => header['batch_hash'],
          'quarantined' => outcome[:quarantined], 'resolved' => outcome[:resolved], 'central_time_us' => Hlc.now_us
        }
        @conn.execute(<<~SQL)
          INSERT INTO sync_received_batches (site_code, server_generation, priority, batch_number, batch_hash, change_count, central_reply_json, received_at)
          VALUES (#{q(@site_code)}, #{header['server_generation'].to_i}, #{q(header['priority'])}, #{batch_number}, #{q(header['batch_hash'])},
                  #{events.size}, #{q(ack.to_json)}, NOW(6))
        SQL
        @conn.execute(<<~SQL)
          UPDATE sync_site_progress SET last_batch_number = #{batch_number}, last_batch_hash = #{q(header['batch_hash'])}, updated_at = NOW(6)
          WHERE site_code = #{q(@site_code)} AND server_generation = #{header['server_generation'].to_i} AND priority = #{q(header['priority'])}
        SQL
        simulate_power_cut!
      end
      Result.new(200, ack)
    end

    CRASH_FLAG = 'tmp/site_sync_crash_next_batch'

    # Prototype fault injection (SITE_SYNC_CHAOS=1 only): if the flag file
    # exists, die after the whole batch has been applied but before COMMIT,
    # like a power cut at the worst moment.
    def simulate_power_cut!
      return unless ENV['SITE_SYNC_CHAOS'] == '1'

      flag = Rails.root.join(CRASH_FLAG)
      return unless File.exist?(flag)

      File.delete(flag)
      raise 'Simulated power cut before COMMIT'
    end

    def lane_state(server_generation, priority)
      @conn.execute(<<~SQL)
        INSERT IGNORE INTO sync_site_progress (site_code, server_generation, priority, last_batch_number, last_batch_hash, updated_at)
        VALUES (#{q(@site_code)}, #{server_generation.to_i}, #{q(priority)}, 0, #{q(GENESIS)}, NOW(6))
      SQL
      row = @conn.select_one(<<~SQL)
        SELECT last_batch_number, last_batch_hash FROM sync_site_progress
        WHERE site_code = #{q(@site_code)} AND server_generation = #{server_generation.to_i} AND priority = #{q(priority)}
      SQL
      { last_batch_number: row['last_batch_number'].to_i, last_batch_hash: row['last_batch_hash'] }
    end

    # ---------------------------------------------------------------------

    def apply_events(events)
      events.each { |event| update_mirror(event) }

      own = events.reject { |e| e['source'] == 'replica' }
      problems = validate(own)
      quarantined = []
      resolved = []
      new_person_uuids = []

      own.each do |event|
        if (problem = problems[event['change_key']])
          quarantine(event, problem)
          quarantined << { 'change_key' => event['change_key'], 'table' => event['table'], 'uuid' => event['uuid'],
                           'reason' => problem[:reason], 'details' => problem[:details] }
          next
        end

        begin
          @conn.transaction(requires_new: true) { apply(event) }
          new_person_uuids << event['uuid'] if event['table'] == 'person' && event['operation'] == 'I'
          fixed_requests = resolve_quarantine(event['uuid'])
          resolved << event['uuid'] if fixed_requests
          # The record is here now (it arrived late, or the site corrected
          # it): retry what was parked waiting for it.
          parked = parked_behind(event['uuid'], Array(fixed_requests).compact, only_parked: true)
          released = apply_parked(parked, status: 'resolved')
          resolved.concat(released.select { |r| r['status'] == 'applied' }.map { |r| r['uuid'] })
        rescue Codec::MissingRef => e
          problem = { reason: 'missing_reference', details: e.message, parent: e.uuid }
          quarantine(event, problem)
          quarantined << { 'change_key' => event['change_key'], 'table' => event['table'], 'uuid' => event['uuid'],
                           'reason' => problem[:reason], 'details' => problem[:details] }
        rescue ActiveRecord::StatementInvalid => e
          problem = { reason: 'database_rejected', details: e.message.slice(0, 500) }
          quarantine(event, problem)
          quarantined << { 'change_key' => event['change_key'], 'table' => event['table'], 'uuid' => event['uuid'],
                           'reason' => problem[:reason], 'details' => problem[:details] }
        end
      end
      # Checked after the whole batch, so a person's name and identifier
      # (usually captured in the same request) have already landed.
      new_person_uuids.each { |uuid| DuplicateDetector.new(@conn).check(uuid) }
      { quarantined:, resolved: resolved.uniq }
    end

    # Central's exact copy of the site's rows (the national backup). Every
    # event goes in, quarantined or not: quarantine is about the national
    # dataset, not about what the site holds.
    def update_mirror(event)
      if event['operation'] == 'D'
        @conn.execute(<<~SQL)
          UPDATE sync_site_backup SET deleted = 1, change_time = #{event['change_time'].to_i}, updated_at = NOW(6)
          WHERE site_code = #{q(@site_code)} AND table_name = #{q(event['table'])} AND row_uuid = #{q(event['uuid'])}
        SQL
        return
      end

      @conn.execute(<<~SQL)
        INSERT INTO sync_site_backup (site_code, table_name, row_uuid, local_id, row_json, row_hash, change_time, deleted, updated_at)
        VALUES (#{q(@site_code)}, #{q(event['table'])}, #{q(event['uuid'])}, #{event['pk'].to_i},
                #{q(event['row'].to_json)}, #{q(event['row_hash'])}, #{event['change_time'].to_i}, 0, NOW(6))
        ON DUPLICATE KEY UPDATE local_id = VALUES(local_id), row_json = VALUES(row_json), row_hash = VALUES(row_hash),
                                change_time = VALUES(change_time), deleted = 0, updated_at = VALUES(updated_at)
      SQL
    end

    # ---- checks 4-7 ------------------------------------------------------

    def validate(events)
      problems = {}
      created = Hash.new { |h, k| h[k] = Set.new }

      events.each do |event|
        problem = check(event, created)
        if problem
          problems[event['change_key']] = problem
        elsif %w[I S R].include?(event['operation'])
          created[event['table']] << event['uuid']
        end
      end

      # Park whatever depends on a quarantined row, and everything else saved
      # by the same API request, until nothing changes.
      loop do
        bad_uuids = events.select { |e| problems[e['change_key']] }.map { |e| e['uuid'] }.to_set
        bad_requests = events.select { |e| problems[e['change_key']] && e['request_id'] }.map { |e| e['request_id'] }.to_set
        added = false
        events.each do |event|
          next if problems[event['change_key']]

          parent = (event['refs'] || {}).values.find { |uuid| uuid && bad_uuids.include?(uuid) }
          if parent
            problems[event['change_key']] = { reason: 'parent_quarantined', details: "depends on #{parent}", parent: }
          elsif event['request_id'] && bad_requests.include?(event['request_id'])
            problems[event['change_key']] = { reason: 'request_parked',
                                            details: "saved by the same request (#{event['request_id']}) as a quarantined record" }
          end
          added ||= problems.key?(event['change_key'])
        end
        break unless added
      end
      problems
    end

    def check(event, created)
      table = event['table']
      return { reason: 'unknown_table', details: table } unless Config.synced?(table)
      return { reason: 'invalid_operation', details: event['operation'] } unless %w[I U D S R].include?(event['operation'])
      return { reason: 'invalid_uuid', details: event['uuid'].inspect } unless event['uuid'].to_s.match?(/\A[0-9a-fA-F-]{32,38}\z/)
      return nil if event['operation'] == 'D'

      row = event['row'] || {}
      refs = event['refs'] || {}

      # 4. types and required values
      missing = Config.required_columns(table) - row.compact.keys
      return { reason: 'missing_required_value', details: missing.join(', ') } if missing.any?

      # 5. ownership: clinical rows may only be changed by the site that created them
      if Config.clinical?(table)
        owner = @conn.select_value(
          "SELECT site_code FROM sync_row_owners WHERE table_name = #{q(table)} AND row_uuid = #{q(event['uuid'])}"
        )
        if owner && owner != @site_code && event['operation'] != 'S'
          return { reason: 'ownership', details: "#{table} #{event['uuid']} belongs to #{owner}; ask #{owner} to void it" }
        end
      end

      # 6. referenced records exist (here, or earlier in this batch)
      Config.refs(table).each do |col, target|
        uuid = refs[col]
        next if uuid.nil? && row[col].nil?
        return { reason: 'missing_reference', details: "#{col} has no uuid" } if uuid.nil?
        next if created[target].include?(uuid) || @codec.id_for(target, uuid)

        parked = @conn.select_value(
          "SELECT 1 FROM sync_quarantine WHERE row_uuid = #{q(uuid)} AND status = 'open' LIMIT 1"
        )
        return { reason: 'parent_quarantined', details: "depends on #{uuid}", parent: uuid } if parked

        return { reason: 'missing_reference', details: "#{col} -> #{target} #{uuid} not found", parent: uuid }
      end
      Config.reference_refs.each do |col, spec|
        next unless row.key?(col) && !row[col].nil?

        if spec['match'] == 'uuid'
          next if @codec.id_for(spec['table'], refs[col])

          return { reason: 'unknown_reference_data', details: "#{col}: #{spec['table']} #{refs[col]} not found" }
        end
        next if reference_exists?(spec['table'], row[col])

        return { reason: 'unknown_reference_data', details: "#{col}: #{spec['table']} #{row[col]} not found" }
      end

      # 7. clinical sanity
      sanity(table, row)
    end

    def reference_exists?(table, id)
      key = [table, id.to_s]
      return @reference_ids[key] if @reference_ids.key?(key)

      pk = @conn.primary_key(table) || "#{table}_id"
      @reference_ids[key] = @conn.select_value("SELECT 1 FROM `#{table}` WHERE `#{pk}` = #{q(id)} LIMIT 1").present?
    end

    def sanity(table, row)
      tomorrow = (Time.now + 1.day).strftime('%F %T')
      case table
      when 'person'
        if row['birthdate'] && (row['birthdate'] > Date.today.to_s || row['birthdate'] < '1900-01-01')
          return { reason: 'clinical_sanity', details: "birthdate #{row['birthdate']} is not plausible" }
        end
        if row['birthdate'] && row['death_date'] && row['death_date'][0, 10] < row['birthdate']
          return { reason: 'clinical_sanity', details: 'death date is before birth date' }
        end
      when 'encounter'
        return { reason: 'clinical_sanity', details: 'encounter is dated in the future' } if row['encounter_datetime'].to_s > tomorrow
      when 'obs'
        return { reason: 'clinical_sanity', details: 'observation is dated in the future' } if row['obs_datetime'].to_s > tomorrow
      end
      nil
    end

    # ---- apply -----------------------------------------------------------

    def apply(event)
      table = event['table']
      uuid = event['uuid']
      id = @codec.id_for(table, uuid)

      if event['operation'] == 'D'
        return unless id

        @conn.execute(<<~SQL)
          INSERT INTO sync_deleted_records (site_code, table_name, row_uuid, row_json, deleted_at)
          VALUES (#{q(@site_code)}, #{q(table)}, #{q(uuid)}, #{q(@store.current(table, id).to_json)}, NOW(6))
        SQL
        Central.publish(table:, operation: 'D', uuid:, from_site: @site_code, codec: @codec, store: @store,
                        seen_change_time: event['change_time'].to_i)
        @store.delete(table, id)
        @codec.forget(table, uuid)
        return
      end

      local = @codec.localize(table, event['row'], event['refs'] || {})
      local['uuid'] = uuid if Config.columns(table).include?('uuid')

      if id.nil?
        @store.insert(table, local)
        @conn.execute(<<~SQL)
          INSERT IGNORE INTO sync_row_owners (table_name, row_uuid, site_code) VALUES (#{q(table)}, #{q(uuid)}, #{q(@site_code)})
        SQL
        record_versions(table, uuid, local.keys, event)
        Central.subscribe(@site_code, uuid, 'own') if table == 'person'
        Central.publish(table:, operation: 'I', uuid:, from_site: @site_code, codec: @codec, store: @store,
                        seen_change_time: event['change_time'].to_i)
        return
      end

      # Rows that predate sync (rollout) belong to the first site that sends them.
      @conn.execute(<<~SQL)
        INSERT IGNORE INTO sync_row_owners (table_name, row_uuid, site_code) VALUES (#{q(table)}, #{q(uuid)}, #{q(@site_code)})
      SQL
      current = @store.current(table, id)
      changes, lost = Config.clinical?(table) ? [differing(local, current), false] : resolve_fields(event, local, current)
      @store.update(table, id, changes)
      if changes.any?
        Central.publish(table:, operation: 'U', uuid:, from_site: @site_code, codec: @codec, store: @store,
                        seen_change_time: event['change_time'].to_i, columns: changes.keys)
      end
      # The site's own copy still holds a value that lost; send it the winner.
      return unless lost

      Central.publish(table:, operation: 'U', uuid:, from_site: @site_code, for_site: @site_code, codec: @codec,
                      store: @store, seen_change_time: event['change_time'].to_i)
    end

    def differing(local, current)
      local.reject { |col, value| col == 'uuid' || same?(value, current[col]) }
    end

    # Field-by-field merge for shared identity rows (design section 5).
    #  - a field the site changed from the value central still holds: applied
    #  - a field changed concurrently elsewhere: newest HLC wins, the other
    #    value is kept in sync_conflicts
    #  - protected fields (national id, sex, birth date, death) are never
    #    resolved automatically: central keeps its value and opens a review
    def resolve_fields(event, local, current)
      table = event['table']
      before = event['before'] || {}
      ref_cols = Config.refs(table).keys + Config.reference_refs.keys
      changes = {}
      lost = false
      # An update only speaks for the columns the site actually changed; the
      # rest of its row may simply be out of date.
      if event['operation'] == 'U'
        edited = (event['row'] || {}).keys.reject { |col| same?(before[col], event['row'][col]) }
        local = local.slice(*edited)
      end

      differing(local, current).each do |col, value|
        version = @conn.select_one(<<~SQL)
          SELECT change_time, site_code FROM sync_field_versions
          WHERE table_name = #{q(table)} AND row_uuid = #{q(event['uuid'])} AND column_name = #{q(col)}
        SQL
        based_on_current = if event['operation'] == 'U' && !ref_cols.include?(col)
                             same?(before[col], current[col])
                           else
                             version.nil? || version['site_code'] == @site_code
                           end

        incoming = [value, @site_code, event['change_time'].to_i]
        existing = [current[col], version&.fetch('site_code'), version&.fetch('change_time')&.to_i]
        if based_on_current
          changes[col] = value
        elsif Config.protected_fields(table).include?(col) || event['clock_clamped']
          # Protected fields, and edits whose clock could not be trusted, go
          # to a data officer instead of last-writer-wins.
          conflict(table, event['uuid'], col, 'protected', kept: existing, losing: incoming)
          lost = true
        elsif version.nil? || event['change_time'].to_i > version['change_time'].to_i
          changes[col] = value
          conflict(table, event['uuid'], col, 'lww', kept: incoming, losing: existing)
        else
          conflict(table, event['uuid'], col, 'lww', kept: existing, losing: incoming)
          lost = true
        end
      end
      record_versions(table, event['uuid'], changes.keys, event)
      [changes, lost]
    end

    # kept / losing: [value, site_code, change_time]. Protected-field conflicts stay
    # open for a data officer; last-writer-wins ones are only logged.
    def conflict(table, uuid, col, conflict_type, kept:, losing:)
      @conn.execute(<<~SQL)
        INSERT INTO sync_conflicts
          (table_name, row_uuid, column_name, conflict_type, kept_value, kept_site, kept_change_time, losing_value, losing_site, losing_change_time,
           status, created_at)
        VALUES (#{q(table)}, #{q(uuid)}, #{q(col)}, #{q(conflict_type)}, #{q(kept[0]&.to_s)}, #{q(kept[1])}, #{q(kept[2])},
                #{q(losing[0]&.to_s)}, #{q(losing[1])}, #{q(losing[2])},
                #{q(conflict_type == 'protected' ? 'open' : 'logged')}, NOW(6))
      SQL
    end

    def record_versions(table, uuid, cols, event)
      return if Config.clinical?(table) || cols.empty?

      values = cols.map { |col| "(#{q(table)}, #{q(uuid)}, #{q(col)}, #{event['change_time'].to_i}, #{q(@site_code)})" }
      @conn.execute(<<~SQL)
        INSERT INTO sync_field_versions (table_name, row_uuid, column_name, change_time, site_code)
        VALUES #{values.join(', ')}
        ON DUPLICATE KEY UPDATE change_time = VALUES(change_time), site_code = VALUES(site_code)
      SQL
    end

    def same?(a, b)
      return a == b if a.nil? || b.nil?
      return a.to_f == b.to_f if a.is_a?(Numeric) || b.is_a?(Numeric)

      a.to_s == b.to_s
    end

    # ---- quarantine -------------------------------------------------------

    def quarantine(event, problem)
      @conn.execute(<<~SQL)
        INSERT INTO sync_quarantine
          (site_code, change_key, table_name, row_uuid, request_id, reason, details, waiting_for_uuid, change_json, status, created_at)
        VALUES (#{q(@site_code)}, #{q(event['change_key'])}, #{q(event['table'])}, #{q(event['uuid'])}, #{q(event['request_id'])},
                #{q(problem[:reason])}, #{q(problem[:details])}, #{q(problem[:parent])}, #{q(event.to_json)}, 'open', NOW(6))
        ON DUPLICATE KEY UPDATE reason = VALUES(reason), details = VALUES(details), status = 'open'
      SQL
    end

    # A later, valid change to a quarantined row (the site fixed it) closes
    # the open quarantine items for that row. Returns their request ids, or
    # nil if the row had nothing open.
    def resolve_quarantine(uuid)
      open = @conn.select_rows(<<~SQL)
        SELECT change_key, request_id FROM sync_quarantine
        WHERE site_code = #{q(@site_code)} AND row_uuid = #{q(uuid)} AND status = 'open'
      SQL
      return nil if open.empty?

      @conn.execute(<<~SQL)
        UPDATE sync_quarantine SET status = 'resolved', resolved_at = NOW(6)
        WHERE site_code = #{q(@site_code)} AND row_uuid = #{q(uuid)} AND status = 'open'
      SQL
      open.map(&:last)
    end

    def refuse(status, error, **details)
      Result.new(status, { 'status' => 'refused', 'error' => error }.merge(details.transform_keys(&:to_s)))
    end

    def q(value)
      @conn.quote(value)
    end
  end
end
