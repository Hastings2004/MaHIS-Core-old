# frozen_string_literal: true

module SiteSync
  # Shared helpers for the central node: registered sites, alerts, the
  # downstream feed and subscriptions.
  module Central
    INGEST_LOCK = 'site_sync_central_feed'

    module_function

    def connection
      ActiveRecord::Base.lease_connection
    end

    def q(value)
      connection.quote(value)
    end

    def site(code)
      connection.select_one("SELECT * FROM sync_sites WHERE site_code = #{q(code)}")
    end

    def register_site(code, name:, secret:, location_id: nil)
      connection.execute(<<~SQL)
        INSERT INTO sync_sites (site_code, name, location_id, secret, status, server_generation, created_at, updated_at)
        VALUES (#{q(code)}, #{q(name)}, #{q(location_id)}, #{q(SecretCipher.encrypt(secret))}, 'active', 1, NOW(6), NOW(6))
        ON DUPLICATE KEY UPDATE name = VALUES(name), location_id = VALUES(location_id),
                                secret = VALUES(secret), updated_at = NOW(6)
      SQL
    end

    # The raw secret for a site row from `site`/`site_code` (its `secret`
    # column is encrypted at rest; see SecretCipher).
    def secret_for(site_row)
      SecretCipher.decrypt(site_row['secret'])
    end

    def alert(site_code, alert_type, message)
      Rails.logger.warn("[SiteSync] #{site_code} #{alert_type}: #{message}")
      connection.execute(<<~SQL)
        INSERT INTO sync_alerts (site_code, alert_type, message, created_at)
        VALUES (#{q(site_code)}, #{q(alert_type)}, #{q(message)}, NOW(6))
      SQL
    end

    # Serialises everything that appends to sync_central_feed, so global_seq order is
    # commit order and a site reading "after my cursor" never skips a change
    # committed late. (A production version would use a committed-watermark
    # table instead of one lock.)
    def with_feed_lock
      got = connection.select_value("SELECT GET_LOCK(#{q(INGEST_LOCK)}, 120)")
      raise 'Could not take the central feed lock' unless got.to_i == 1

      yield
    ensure
      connection.select_value("SELECT RELEASE_LOCK(#{q(INGEST_LOCK)})") if got.to_i == 1
    end

    # Central's own HLC, so feed events always carry increasing clocks.
    def next_hlc(seen = 0)
      value = Hlc.receive(State.get_i('central_change_time', 0), seen)
      State.set('central_change_time', value)
      value
    end

    # Append a central row to the downstream feed: the whole row, or with
    # `columns` only those columns (an update sends just what changed, so a
    # site never gets other fields overwritten with an older state).
    # for_site nil = everyone subscribed to the patient except from_site.
    def publish(table:, operation:, uuid:, from_site:, codec:, store:, for_site: nil, seen_change_time: 0, columns: nil)
      full = operation == 'D' ? nil : store.current(table, codec.id_for(table, uuid))
      return if operation != 'D' && full.nil?

      refs = full ? codec.encode_refs(table, full) : {}
      patient_uuid = full ? Codec.patient_uuid(table, uuid, refs) : patient_of_deleted(table, uuid)
      row = columns && full ? full.slice(*columns) : full
      refs = refs.slice(*columns) if columns
      change_time = next_hlc(seen_change_time)
      event = { 'table' => table, 'operation' => operation, 'uuid' => uuid, 'change_time' => change_time, 'row' => row, 'refs' => refs }
      connection.execute(<<~SQL)
        INSERT INTO sync_central_feed
          (from_site, for_site, table_name, operation, row_uuid, patient_uuid, change_time, change_json, created_at)
        VALUES (#{q(from_site)}, #{q(for_site)}, #{q(table)}, #{q(operation)}, #{q(uuid)}, #{q(patient_uuid)},
                #{change_time}, #{q(event.to_json)}, NOW(6))
      SQL
    end

    def patient_of_deleted(table, uuid)
      connection.select_value(<<~SQL)
        SELECT patient_uuid FROM sync_central_feed
        WHERE table_name = #{q(table)} AND row_uuid = #{q(uuid)} AND patient_uuid IS NOT NULL
        ORDER BY global_seq DESC LIMIT 1
      SQL
    end

    def subscribe(site_code, patient_uuid, reason)
      connection.execute(<<~SQL)
        INSERT IGNORE INTO sync_subscriptions (site_code, patient_uuid, reason, created_at)
        VALUES (#{q(site_code)}, #{q(patient_uuid)}, #{q(reason)}, NOW(6))
      SQL
    end
  end
end
