# frozen_string_literal: true

module SiteSync
  # Every synced row belonging to one patient, as wire events, parents first.
  # Used when a site fetches a patient on demand (referral or walk-in).
  class PatientRecord
    def initialize(connection = ActiveRecord::Base.lease_connection)
      @conn = connection
      @codec = Codec.new(@conn)
      @store = RowStore.new(@conn)
    end

    def events(patient_uuid)
      person_id = @codec.id_for('person', patient_uuid)
      return [] unless person_id

      # Newer than anything already in the feed, so a feed event that arrives
      # after this snapshot cannot overwrite it with older data.
      change_time = Central.next_hlc
      Config.table_names.flat_map do |table|
        column = Config.patient_ref(table) == 'self' ? Config.pk(table) : Config.patient_ref(table)
        ids = @conn.select_values(
          "SELECT `#{Config.pk(table)}` FROM `#{table}` WHERE `#{column}` = #{person_id} ORDER BY `#{Config.pk(table)}`"
        )
        ids.map do |id|
          row = @store.current(table, id)
          uuid = Config.uuid_via(table) ? patient_uuid : row['uuid']
          { 'table' => table, 'operation' => 'I', 'uuid' => uuid, 'change_time' => change_time, 'row' => row,
            'refs' => @codec.encode_refs(table, row) }
        end
      end
    end
  end
end
