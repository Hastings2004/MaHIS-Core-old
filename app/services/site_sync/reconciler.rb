# frozen_string_literal: true

module SiteSync
  # Nightly check that central's backup copy of this site matches the site,
  # row for row, and repair of whatever does not.
  #
  # Both sides are compared at the same point in the change sequence: the run
  # only starts once everything captured has been acknowledged, and rows with
  # changes still in flight are left for the next run.
  #
  # Repair policy:
  #   row only at the site     -> re-sent to central (a change that escaped capture)
  #   row only at central      -> central's copy is written back (the site lost it)
  #   row on both, different   -> held for a data officer. Either side could be
  #                               right: the site row may be corrupted, or it may
  #                               hold a real change that escaped capture (a
  #                               migration, a paused session). The officer
  #                               decides per row (central_uuids / site_uuids),
  #                               or for every held row at once (different:).
  class Reconciler
    DIFFERENT_POLICIES = [nil, 'central', 'site'].freeze

    def initialize(client: Client.new)
      @client = client
      @conn = ActiveRecord::Base.lease_connection
      @bytes = 0
    end

    # different:     'central' or 'site' settles every differing row that way.
    # central_uuids: rows where central's copy is right (written back here).
    # site_uuids:    rows where this site's copy is right (re-sent to central).
    def run(repair: true, different: nil, central_uuids: [], site_uuids: [], tables: Config.table_names)
      raise ArgumentError, "different must be one of #{DIFFERENT_POLICIES.inspect}" unless DIFFERENT_POLICIES.include?(different)
      raise ArgumentError, 'a row cannot be settled both ways' if (central_uuids & site_uuids).any?

      @decisions = { different:, central: central_uuids, site: site_uuids }
      Sender.new(client: @client).run_once
      return finish(started = Time.now, 'skipped', { 'reason' => 'backlog not yet acknowledged' }) if backlog?

      started = Time.now
      report = tables.index_with { |table| reconcile(table, repair:) }
      finish(started, 'completed', report)
    end

    private

    def reconcile(table, repair:)
      level1 = Merkle.site_digests(@conn, table, 2)
      prefixes = compare(table, 2, level1, nil)
      return { 'differences' => 0 } if prefixes.empty?

      level2 = Merkle.site_digests(@conn, table, 4, prefixes)
      prefixes = compare(table, 4, level2, prefixes)
      return { 'differences' => 0 } if prefixes.empty?

      rows = @conn.select_rows(<<~SQL).to_h
        SELECT x.row_uuid, x.row_hash FROM (#{RowSql.hashed_rows(table)}) x
        WHERE LEFT(x.row_uuid, 4) IN (#{prefixes.map { |p| @conn.quote(p) }.join(', ')})
      SQL
      diff = call('/api/v1/site_sync/merkle/rows', { table:, prefixes:, rows: })
      in_flight = in_flight_uuids(table)
      site_only = diff['site_only'] - in_flight
      central_only = diff['central_only'] - in_flight
      changed = diff['different'] - in_flight

      to_site = @decisions[:different] == 'central' ? changed : changed & @decisions[:central]
      to_central = @decisions[:different] == 'site' ? changed : changed & @decisions[:site]
      if repair
        resend(table, site_only + to_central)
        write_back(table, central_only + to_site)
      end
      held = repair ? changed - to_site - to_central : changed
      { 'differences' => site_only.size + central_only.size + changed.size, 'site_only' => site_only,
        'central_only' => central_only, 'different' => changed, 'held_for_review' => held,
        'repaired' => repair }
    end

    def compare(table, prefix_len, digests, within)
      call('/api/v1/site_sync/merkle', { table:, prefix_len:, within:, digests: })['differing']
    end

    def call(path, payload)
      response = @client.post(path, payload)
      @bytes += response.bytes_sent + response.bytes_received
      raise "Reconciliation refused: HTTP #{response.status} #{response.body}" unless response.status == 200

      response.body
    end

    def backlog?
      @conn.select_value(<<~SQL).to_i.positive?
        SELECT COUNT(*) FROM sync_change_log l LEFT JOIN sync_batches b ON b.id = l.batch_id
        WHERE l.batch_id IS NULL OR b.status <> 'acked'
      SQL
    end

    def in_flight_uuids(table)
      @conn.select_values(<<~SQL)
        SELECT DISTINCT l.row_uuid FROM sync_change_log l LEFT JOIN sync_batches b ON b.id = l.batch_id
        WHERE l.table_name = #{@conn.quote(table)} AND (l.batch_id IS NULL OR b.status <> 'acked')
      SQL
    end

    # Queue the row again as a repair event; the next push carries it.
    def resend(table, uuids)
      return if uuids.empty?

      uuid_col = Config.uuid_via(table) ? 'v.`uuid`' : 't.`uuid`'
      join = if (via = Config.uuid_via(table))
               "JOIN `#{via}` v ON v.`#{Config.pk(via)}` = t.`#{Config.pk(table)}`"
             else
               ''
             end
      @conn.execute(<<~SQL)
        INSERT INTO sync_change_log
          (priority, table_name, operation, local_id, row_uuid, before_json, after_json, row_hash, source, job, captured_at)
        SELECT #{@conn.quote(Config.priority(table))}, #{@conn.quote(table)}, 'R', t.`#{Config.pk(table)}`, #{uuid_col},
               NULL, #{RowSql.json(table, 't.')}, #{RowSql.hash_expr(table, 't.')}, 'local', 'reconcile:resend', NOW(6)
        FROM `#{table}` t #{join}
        WHERE #{uuid_col} IN (#{uuids.map { |u| @conn.quote(u) }.join(', ')})
      SQL
      Sender.new(client: @client).run_once
    end

    # Write central's copy back exactly (original ids), without capturing it:
    # central already holds it.
    def write_back(table, uuids)
      return if uuids.empty?

      rows = call('/api/v1/site_sync/mirror_rows', { table:, uuids: })['rows']
      store = RowStore.new(@conn)
      Context.capture_paused do
        @conn.execute('SET FOREIGN_KEY_CHECKS = 0')
        @conn.transaction { rows.each { |row| store.put_exact(table, row['row']) } }
      ensure
        @conn.execute('SET FOREIGN_KEY_CHECKS = 1')
      end
    end

    def finish(started, status, report)
      summary = { 'status' => status, 'tables' => report, 'bytes_exchanged' => @bytes,
                  'seconds' => (Time.now - started).round(2) }
      @conn.execute(<<~SQL)
        INSERT INTO sync_reconciliation_runs (site_code, status, report_json, bytes_exchanged, started_at, finished_at)
        VALUES (#{@conn.quote(Config.site_code)}, #{@conn.quote(status)}, #{@conn.quote(summary.to_json)}, #{@bytes},
                #{@conn.quote(started)}, NOW(6))
      SQL
      begin
        @client.post('/api/v1/site_sync/reconciliation_report', summary)
      rescue Client::Unreachable
        nil
      end
      summary
    end
  end
end
