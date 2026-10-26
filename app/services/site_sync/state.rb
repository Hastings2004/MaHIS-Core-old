# frozen_string_literal: true

module SiteSync
  # Small key/value store (sync_state) for the agent's durable state: server_generation,
  # last HLC, pull cursor. Writes join the caller's transaction, so state moves
  # forward only together with the data it describes.
  module State
    module_function

    def connection
      ActiveRecord::Base.lease_connection
    end

    def get(name, default = nil)
      value = connection.select_value("SELECT value FROM sync_state WHERE name = #{connection.quote(name)}")
      value.nil? ? default : value
    end

    def get_i(name, default = 0)
      Integer(get(name, default))
    end

    def set(name, value)
      connection.execute(<<~SQL)
        INSERT INTO sync_state (name, value, updated_at)
        VALUES (#{connection.quote(name)}, #{connection.quote(value.to_s)}, NOW(6))
        ON DUPLICATE KEY UPDATE value = VALUES(value), updated_at = VALUES(updated_at)
      SQL
    end

    def server_generation
      get_i('server_generation', 1)
    end

    # Checked on every API request while sync is on, so cached briefly.
    def restoring?
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @mode_checked_at.nil? || now - @mode_checked_at > 5
        @restoring = get('mode', 'normal') == 'restoring'
        @mode_checked_at = now
      end
      @restoring
    end
  end
end
