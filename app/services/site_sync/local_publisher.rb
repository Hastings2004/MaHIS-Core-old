# frozen_string_literal: true

module SiteSync
  # Central captures its own changes exactly like a site does -- same
  # triggers, same sync_change_log -- but there is nowhere to push them: no
  # batch, no HTTP, no other end to validate against. This walks central's
  # own outbox and publishes each row straight to the feed, the same call
  # CentralCorrection already makes successfully today
  # (Central.publish(from_site: 'CENTRAL', ...)). CentralIngest is the wrong
  # layer to reuse here: its whole job is turning an untrusted site's batch
  # into local rows, and central's own rows are already correctly in its
  # tables -- there is nothing left to apply, only to announce.
  class LocalPublisher
    SITE_CODE = 'CENTRAL'

    def initialize(connection = ActiveRecord::Base.lease_connection)
      @conn = connection
      @codec = Codec.new(@conn)
      @store = RowStore.new(@conn)
    end

    # Returns the number of rows published.
    def run_once(limit: 500)
      rows = @conn.select_all(<<~SQL).to_a
        SELECT * FROM sync_change_log WHERE id > #{State.get_i('local_publish_cursor', 0)}
        ORDER BY id LIMIT #{limit}
      SQL
      return 0 if rows.empty?

      Central.with_feed_lock do
        @conn.transaction do
          rows.each { |row| publish_one(row) }
          State.set('local_publish_cursor', rows.last['id'])
        end
      end
      rows.size
    end

    private

    def publish_one(row)
      table = row['table_name']
      uuid = row['row_uuid']
      # A rollout snapshot ('S', queued by rake site_sync:snapshot for rows
      # that predate sync) reads downstream as an ordinary update.
      operation = row['operation'] == 'S' ? 'U' : row['operation']

      # Rows that predate sync belong to whoever announces them first --
      # same rule CentralIngest applies to a site's own pre-existing rows.
      @conn.execute(<<~SQL)
        INSERT IGNORE INTO sync_row_owners (table_name, row_uuid, site_code) VALUES (#{q(table)}, #{q(uuid)}, #{q(SITE_CODE)})
      SQL

      changed_cols = changed_columns(row)
      record_field_versions(table, uuid, changed_cols, row) if operation != 'D' && !Config.clinical?(table)

      Central.subscribe(SITE_CODE, uuid, 'own') if table == 'person' && operation != 'D'
      Central.publish(table:, operation:, uuid:, from_site: SITE_CODE, codec: @codec, store: @store,
                      seen_change_time: Hlc.from_time(row['captured_at']),
                      columns: operation == 'U' && changed_cols.any? ? changed_cols : nil)
    end

    # Which columns actually changed, from the before/after snapshot the
    # trigger captured -- an insert or snapshot has no "before", so every
    # captured column counts.
    def changed_columns(row)
      after = row['after_json'] ? JSON.parse(row['after_json']) : {}
      before = row['before_json'] ? JSON.parse(row['before_json']) : nil
      return after.keys if before.nil?

      after.keys.reject { |col| after[col] == before[col] }
    end

    # Central's own direct edits need to win or lose field-level conflicts
    # the same way a site's do (CentralIngest#resolve_fields reads this
    # table) -- only shared_identity tables use field-level resolution;
    # clinical tables (encounter, obs) are ownership-based instead.
    def record_field_versions(table, uuid, cols, row)
      return if cols.empty?

      change_time = Hlc.from_time(row['captured_at'])
      values = cols.map { |col| "(#{q(table)}, #{q(uuid)}, #{q(col)}, #{change_time}, #{q(SITE_CODE)})" }
      @conn.execute(<<~SQL)
        INSERT INTO sync_field_versions (table_name, row_uuid, column_name, change_time, site_code)
        VALUES #{values.join(', ')}
        ON DUPLICATE KEY UPDATE change_time = VALUES(change_time), site_code = VALUES(site_code)
      SQL
    end

    def q(value)
      @conn.quote(value)
    end
  end
end
