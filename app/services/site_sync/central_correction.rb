# frozen_string_literal: true

module SiteSync
  # Central decisions (design section 3): "patient merges, data corrections
  # -- central only; sent to affected sites as commands." Used for the fields
  # normal sync deliberately never auto-resolves (national id, sex, birth
  # date, death status -- see config/site_sync_tables.yml protected_fields)
  # once a data officer has looked at the conflict and judged which value is
  # right. Updates central's own copy and publishes it downstream exactly
  # like any other change; DownstreamApplier needs no special case for it.
  class CentralCorrection
    class InvalidCorrection < StandardError; end

    def initialize(connection = ActiveRecord::Base.lease_connection)
      @conn = connection
      @codec = Codec.new(@conn)
      @store = RowStore.new(@conn)
    end

    def apply(table:, uuid:, changes:, reason: nil)
      raise InvalidCorrection, "#{table} is not a synced table" unless Config.synced?(table)

      changes = changes.transform_keys(&:to_s)
      unknown = changes.keys - Config.columns(table)
      raise InvalidCorrection, "unknown column(s): #{unknown.join(', ')}" if unknown.any?

      id = @codec.id_for(table, uuid)
      raise InvalidCorrection, "#{table} #{uuid} not found" unless id

      previous = @store.current(table, id).slice(*changes.keys)

      Central.with_feed_lock do
        @conn.transaction do
          @store.update(table, id, changes)
          @conn.execute(<<~SQL)
            INSERT INTO sync_central_corrections (table_name, row_uuid, changes_json, previous_json, reason, created_at)
            VALUES (#{q(table)}, #{q(uuid)}, #{q(changes.to_json)}, #{q(previous.to_json)}, #{q(reason)}, NOW(6))
          SQL
          Central.publish(table:, operation: 'U', uuid:, from_site: 'CENTRAL', codec: @codec, store: @store,
                          seen_change_time: Central.next_hlc, columns: changes.keys)
        end
      end
      { 'table' => table, 'uuid' => uuid, 'changed' => changes.keys, 'previous' => previous }
    end

    private

    def q(value)
      @conn.quote(value)
    end
  end
end
