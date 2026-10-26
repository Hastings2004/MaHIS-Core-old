# frozen_string_literal: true

module SiteSync
  # Applies a change received from central to this site's database.
  #
  # - Runs as "replica": the capture triggers log it (for audit and for
  #   central's backup copy) but it is never sent back up as the site's own edit.
  # - An event older than the newest one already applied to the row is skipped.
  # - Columns the site has changed locally and central has not yet
  #   acknowledged are left alone: central will resolve them and send the
  #   result back.
  class DownstreamApplier
    def initialize(connection = ActiveRecord::Base.lease_connection)
      @conn = connection
      @codec = Codec.new(@conn)
      @store = RowStore.new(@conn)
    end

    # Returns :applied, :stale or :skipped. Raises Codec::MissingRef when a
    # referenced row has not arrived yet.
    def apply(event)
      table = event['table']
      uuid = event['uuid']
      change_time = event['change_time'].to_i
      seen = @conn.select_value(
        "SELECT change_time FROM sync_row_versions WHERE table_name = #{q(table)} AND row_uuid = #{q(uuid)}"
      )
      return :stale if seen && seen.to_i >= change_time

      result = Context.as_replica { write(table, uuid, event) }
      @conn.execute(<<~SQL)
        INSERT INTO sync_row_versions (table_name, row_uuid, change_time, site_code) VALUES (#{q(table)}, #{q(uuid)}, #{change_time}, 'central')
        ON DUPLICATE KEY UPDATE change_time = VALUES(change_time)
      SQL
      result
    end

    private

    def write(table, uuid, event)
      id = @codec.id_for(table, uuid)
      if event['operation'] == 'D'
        @store.delete(table, id) if id
        @codec.forget(table, uuid)
        return :applied
      end

      local = @codec.localize(table, event['row'], event['refs'] || {})
      local['uuid'] = uuid if Config.columns(table).include?('uuid')
      if id.nil?
        # An update carries only the changed columns; without the row there
        # is nothing to apply it to yet (it is parked until the row arrives).
        raise Codec::MissingRef.new(table, uuid, 'row') if event['operation'] == 'U'

        @store.insert(table, local)
        return :applied
      end

      pending = pending_columns(table, uuid)
      return :skipped if pending == :all

      current = @store.current(table, id)
      changes = local.reject do |col, value|
        col == 'uuid' || pending.include?(col) || value.to_s == current[col].to_s
      end
      @store.update(table, id, changes)
      changes.empty? ? :skipped : :applied
    end

    # Columns changed by this site's own edits that central has not yet
    # acknowledged; :all if the row itself was created locally and is unsent.
    def pending_columns(table, uuid)
      rows = @conn.select_all(<<~SQL).to_a
        SELECT l.operation, l.before_json, l.after_json FROM sync_change_log l
        LEFT JOIN sync_batches b ON b.id = l.batch_id
        WHERE l.table_name = #{q(table)} AND l.row_uuid = #{q(uuid)} AND l.source = 'local'
          AND (l.batch_id IS NULL OR b.status <> 'acked')
      SQL
      return :all if rows.any? { |r| r['operation'] == 'I' }

      rows.each_with_object(Set.new) do |r, cols|
        before = r['before_json'] ? JSON.parse(r['before_json']) : {}
        after = r['after_json'] ? JSON.parse(r['after_json']) : {}
        after.each { |col, value| cols << col unless before[col] == value }
      end
    end

    def q(value)
      @conn.quote(value)
    end
  end
end
