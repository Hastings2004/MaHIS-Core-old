# frozen_string_literal: true

module SiteSync
  # Every 5 minutes: tell central how far behind this site is and what its
  # clock says, so the dashboard can show lag and clock drift.
  class Heartbeat
    def initialize(client: Client.new)
      @client = client
      @conn = ActiveRecord::Base.lease_connection
    end

    def status
      unsent = @conn.select_all(<<~SQL).to_a
        SELECT l.priority, COUNT(*) AS events, MIN(l.captured_at) AS oldest
        FROM sync_change_log l LEFT JOIN sync_batches b ON b.id = l.batch_id
        WHERE l.batch_id IS NULL OR b.status <> 'acked'
        GROUP BY l.priority
      SQL
      oldest = unsent.map { |r| r['oldest'] }.compact.min
      {
        'site_time_us' => Hlc.now_us,
        'server_generation' => State.server_generation,
        'mode' => State.get('mode', 'normal'),
        'backlog' => unsent.to_h { |r| [r['priority'], r['events'].to_i] },
        'oldest_unsent_seconds' => oldest ? (Time.now - oldest).round : 0,
        'open_quarantine' => @conn.select_value("SELECT COUNT(*) FROM sync_quarantine_notices WHERE status = 'open'").to_i,
        'pending_apply' => @conn.select_value('SELECT COUNT(*) FROM sync_waiting_changes WHERE orphaned_at IS NULL').to_i,
        'orphaned' => @conn.select_value('SELECT COUNT(*) FROM sync_waiting_changes WHERE orphaned_at IS NOT NULL').to_i,
        'pull_cursor' => State.get_i('pull_cursor', 0),
        'triggers_installed' => installed_triggers.size,
        'triggers_expected' => TriggerGenerator.expected_trigger_names.size,
        'facility' => facility
      }
    end

    # The facility this site serves, from MaHIS's own location table, so
    # central shows the real name instead of a code.
    def facility
      id = Config.site_location_id
      return nil unless id

      @conn.select_one("SELECT location_id, name, uuid FROM location WHERE location_id = #{@conn.quote(id)}")
    end

    def installed_triggers
      @conn.select_values(<<~SQL)
        SELECT TRIGGER_NAME FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA = #{@conn.quote(@conn.current_database)} AND TRIGGER_NAME LIKE 'site\\_sync\\_%'
      SQL
    end

    def send_once
      response = @client.post('/api/v1/site_sync/heartbeat', status)
      response.body
    rescue Client::Unreachable
      nil
    end
  end
end
