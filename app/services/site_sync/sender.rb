# frozen_string_literal: true

module SiteSync
  # Site -> central. Seals captured changes into ordered, hash-chained batches
  # and pushes them, critical priority first.
  #
  # A batch is stored (sync_batches) before it is sent, so a resend after a
  # lost acknowledgement is byte-for-byte the same batch. A batch counts as
  # sent only when central's acknowledgement names its sequence number and
  # hash, which central returns only after the batch has committed.
  class Sender
    GENESIS = '0' * 64
    SEAL_LOCK = 'site_sync_seal'

    attr_reader :stats

    def initialize(client: Client.new)
      @client = client
      @conn = ActiveRecord::Base.lease_connection
      @stats = Hash.new(0)
    end

    # Push until there is nothing left (or central cannot be reached).
    # Returns :idle, :sent or :offline.
    def run_once(max_batches: 500)
      sent = false
      Config::LANES.each do |priority|
        max_batches.times do
          batch = next_unacked(priority) || seal(priority)
          break unless batch

          result = push(batch)
          return :offline if result == :offline
          break if result == :refused

          sent = true
        end
        # Bulk rows (visits, observations) point at critical rows (patients):
        # hold them back while the critical priority is stuck.
        break if priority == 'critical' && next_unacked('critical')
      end
      sent ? :sent : :idle
    end

    # Group unsealed log rows into the next batch of a priority. Runs at READ
    # COMMITTED so it takes no gap locks: triggers keep inserting while it
    # works, and anything committed after this read goes in the next batch.
    def seal(priority)
      with_seal_lock do
        @conn.transaction(isolation: :read_committed) do
          rows = @conn.select_all(<<~SQL).to_a
            SELECT * FROM sync_change_log WHERE batch_id IS NULL AND priority = #{q(priority)}
            ORDER BY id LIMIT #{Config.batch_max_events}
          SQL
          return nil if rows.empty?

          events = build_events(rows)
          server_generation = State.server_generation
          last = @conn.select_one(<<~SQL)
            SELECT batch_number, batch_hash FROM sync_batches WHERE server_generation = #{server_generation} AND priority = #{q(priority)} ORDER BY batch_number DESC LIMIT 1
          SQL
          batch_number = last ? last['batch_number'].to_i + 1 : 1
          previous_batch_hash = last ? last['batch_hash'] : GENESIS
          events_json = events.to_json
          batch_hash = Digest::SHA256.hexdigest("#{previous_batch_hash}#{events_json}")
          header = { 'site' => Config.site_code, 'server_generation' => server_generation, 'priority' => priority, 'batch_number' => batch_number,
                     'previous_batch_hash' => previous_batch_hash, 'batch_hash' => batch_hash, 'schema_version' => Config.schema_version,
                     'change_count' => events.size }
          payload = { 'header' => header, 'events_json' => events_json }.to_json

          @conn.execute(<<~SQL)
            INSERT INTO sync_batches (priority, server_generation, batch_number, first_change_id, last_change_id, change_count, previous_batch_hash, batch_hash,
                                      payload, status, created_at)
            VALUES (#{q(priority)}, #{server_generation}, #{batch_number}, #{events.first['log_id']}, #{events.last['log_id']}, #{events.size},
                    #{q(previous_batch_hash)}, #{q(batch_hash)}, #{q(payload)}, 'sealed', NOW(6))
          SQL
          batch_id = @conn.select_value('SELECT LAST_INSERT_ID()')
          @conn.execute(<<~SQL)
            UPDATE sync_change_log SET batch_id = #{batch_id}
            WHERE id IN (#{events.map { |e| e['log_id'] }.join(',')})
          SQL
          @stats[:sealed_events] += events.size
          @conn.select_one("SELECT * FROM sync_batches WHERE id = #{batch_id}")
        end
      end
    end

    def push(batch)
      response = @client.post('/api/v1/site_sync/batches', batch['payload'])
      @stats[:bytes_sent] += response.bytes_sent
      body = response.body

      if response.status == 200 && body['last_batch_number'].to_i == batch['batch_number'].to_i && body['batch_hash'] == batch['batch_hash']
        acknowledge(batch, body)
        :acked
      elsif response.status == 409 && body['expected_seq'] && body['error'] == 'sequence_gap'
        rewind(batch['priority'], body['expected_seq'].to_i)
        :rewound
      else
        note_failure(batch, "HTTP #{response.status}: #{body.to_json.slice(0, 400)}")
        :refused
      end
    rescue Client::Unreachable => e
      note_failure(batch, e.message)
      :offline
    end

    private

    # Wire events: the row exactly as the site holds it, plus uuids for every
    # foreign key. The HLC is assigned here, in log order, from the persisted
    # last value, so it never goes backwards.
    def build_events(rows)
      codec = Codec.new(@conn)
      change_time = State.get_i('change_time', 0)
      bytes = 0
      events = []
      rows.each do |row|
        after = row['after_json'] && JSON.parse(row['after_json'])
        before = row['before_json'] && JSON.parse(row['before_json'])
        change_time = Hlc.tick(change_time, Hlc.from_time(row['captured_at']))
        event = {
          'change_key' => "#{Config.site_code}-#{State.server_generation}-#{row['id']}", 'log_id' => row['id'],
          'table' => row['table_name'], 'operation' => row['operation'], 'uuid' => row['row_uuid'], 'pk' => row['local_id'],
          'change_time' => change_time, 'row' => after, 'before' => before,
          'refs' => after ? codec.encode_refs(row['table_name'], after) : {},
          'row_hash' => row['row_hash'], 'source' => row['source'],
          'request_id' => row['request_id'], 'endpoint' => row['endpoint'], 'job' => row['job'],
          'user_uuid' => row['user_uuid'], 'captured_at' => row['captured_at'].iso8601(6)
        }
        bytes += event.to_json.bytesize
        break if events.any? && bytes > Config.batch_max_bytes

        events << event
      end
      State.set('change_time', change_time)
      events
    end

    def acknowledge(batch, ack)
      @conn.transaction do
        recover_clock(ack['central_time_us'].to_i)
        @conn.execute(<<~SQL)
          UPDATE sync_batches SET status = 'acked', acknowledged_at = NOW(6), central_reply_json = #{q(ack.to_json)}, last_error = NULL
          WHERE id = #{batch['id']}
        SQL
        Array(ack['quarantined']).each do |item|
          @conn.execute(<<~SQL)
            INSERT INTO sync_quarantine_notices (change_key, table_name, row_uuid, reason, details, status, created_at)
            VALUES (#{q(item['change_key'])}, #{q(item['table'])}, #{q(item['uuid'])}, #{q(item['reason'])},
                    #{q(item['details'])}, 'open', NOW(6))
            ON DUPLICATE KEY UPDATE reason = VALUES(reason), details = VALUES(details)
          SQL
        end
        Array(ack['resolved']).each do |uuid|
          @conn.execute(<<~SQL)
            UPDATE sync_quarantine_notices SET status = 'resolved', resolved_at = NOW(6)
            WHERE row_uuid = #{q(uuid)} AND status = 'open'
          SQL
        end
      end
      @stats[:acked_batches] += 1
      @stats[:acked_events] += batch['change_count'].to_i
      @stats[:quarantined] += Array(ack['quarantined']).size
    end

    # The stored HLC never goes backwards on its own, so after a clock that
    # ran ahead is corrected it would stay ahead for as long as the clock was
    # wrong. Pull it back to central's time once central has told us its time.
    def recover_clock(central_us)
      return unless central_us.positive?

      stored = State.get_i('change_time', 0)
      return unless stored > central_us + Config.max_clock_ahead_us

      State.set('change_time', central_us)
      @stats[:clock_reset] += 1
    end

    # Central expects an earlier sequence number than the one we sent (it
    # lost batches, for example after its own restore): send again from there.
    # Batches are kept locally, so nothing has to be rebuilt.
    def rewind(priority, expected_seq)
      @conn.execute(<<~SQL)
        UPDATE sync_batches SET status = 'sealed'
        WHERE server_generation = #{State.server_generation} AND priority = #{q(priority)} AND batch_number >= #{expected_seq}
      SQL
      @conn.execute(<<~SQL)
        UPDATE sync_batches SET status = 'acked', acknowledged_at = COALESCE(acknowledged_at, NOW(6))
        WHERE server_generation = #{State.server_generation} AND priority = #{q(priority)} AND batch_number < #{expected_seq}
      SQL
      @stats[:rewinds] += 1
    end

    def note_failure(batch, message)
      @conn.execute(<<~SQL)
        UPDATE sync_batches SET attempts = attempts + 1, last_error = #{q(message.slice(0, 1000))} WHERE id = #{batch['id']}
      SQL
      @stats[:failures] += 1
    end

    def next_unacked(priority)
      @conn.select_one(<<~SQL)
        SELECT * FROM sync_batches WHERE server_generation = #{State.server_generation} AND priority = #{q(priority)} AND status = 'sealed'
        ORDER BY batch_number LIMIT 1
      SQL
    end

    def with_seal_lock
      got = @conn.select_value("SELECT GET_LOCK(#{q(SEAL_LOCK)}, 30)")
      raise 'Could not take the seal lock' unless got.to_i == 1

      yield
    ensure
      @conn.select_value("SELECT RELEASE_LOCK(#{q(SEAL_LOCK)})") if got.to_i == 1
    end

    def q(value)
      @conn.quote(value)
    end
  end
end
