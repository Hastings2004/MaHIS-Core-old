# frozen_string_literal: true

module SiteSync
  # Reads config/site_sync_tables.yml and the node's role from the environment.
  #
  #   MAHIS_SYNC_ROLE        site | central
  #   MAHIS_SITE_CODE        e.g. SITEA (sites only)
  #   SITE_SYNC_CENTRAL_URL  e.g. https://central.example/ (sites only)
  #   SITE_SYNC_SECRET       the site's shared secret for signing batches (sites only)
  #   SITE_SYNC_ADMIN_TOKEN  protects central's admin and dashboard endpoints
  module Config
    LANES = %w[critical bulk].freeze

    module_function

    def file
      @file ||= YAML.safe_load(File.read(Rails.root.join('config/site_sync_tables.yml')))
    end

    def reload!
      @file = nil
      @columns = nil
      @required = nil
    end

    def schema_version
      file.fetch('schema_version')
    end

    def tables
      file.fetch('tables')
    end

    # Synced tables in dependency order (parents first).
    def table_names
      tables.keys
    end

    def table(name)
      tables.fetch(name.to_s)
    end

    def synced?(name)
      tables.key?(name.to_s)
    end

    def pk(name)
      table(name).fetch('pk')
    end

    def priority(name)
      table(name).fetch('priority')
    end

    def table_class(name)
      table(name).fetch('class')
    end

    def clinical?(name)
      table_class(name) == 'clinical'
    end

    def refs(name)
      table(name).fetch('refs', {}) || {}
    end

    def protected_fields(name)
      table(name).fetch('protected_fields', []) || []
    end

    # Table whose uuid this table borrows (patient -> person), or nil.
    def uuid_via(name)
      table(name)['uuid_via']
    end

    def patient_ref(name)
      table(name).fetch('patient_ref')
    end

    def reference_refs
      file.fetch('reference_refs', {}) || {}
    end

    def unsynced_refs
      file.fetch('unsynced_refs', []) || []
    end

    # Ordered column names of a synced table, read from the live schema.
    def columns(name)
      @columns ||= {}
      @columns[name.to_s] ||= ActiveRecord::Base.connection.select_values(<<~SQL)
        SELECT COLUMN_NAME FROM information_schema.COLUMNS
        WHERE #{table_filter(name)}
        ORDER BY ORDINAL_POSITION
      SQL
    end

    # Columns that must be present on insert: NOT NULL, no default, not the
    # auto-increment key.
    def required_columns(name)
      @required ||= {}
      # Filtered in Ruby: information_schema computes IS_NULLABLE and EXTRA
      # with their own collation, so comparing them to literals fails.
      @required[name.to_s] ||= ActiveRecord::Base.connection.select_rows(<<~SQL)
        SELECT COLUMN_NAME, IS_NULLABLE, COLUMN_DEFAULT, EXTRA FROM information_schema.COLUMNS
        WHERE #{table_filter(name)}
      SQL
        .select { |_, nullable, default, extra| nullable == 'NO' && default.nil? && !extra.to_s.include?('auto_increment') }
        .map(&:first)
    end

    # Compares with the quoted database name rather than DATABASE(), whose
    # collation differs from the connection's and makes MySQL refuse the "=".
    def table_filter(name)
      connection = ActiveRecord::Base.connection
      "TABLE_SCHEMA = #{connection.quote(connection.current_database)} AND TABLE_NAME = #{connection.quote(name.to_s)}"
    end

    # Sync is off unless MAHIS_SYNC_ROLE is set, so existing deployments are
    # unaffected.
    def enabled?
      ENV['MAHIS_SYNC_ROLE'].present?
    end

    def role
      ENV.fetch('MAHIS_SYNC_ROLE', nil)
    end

    def central?
      role == 'central'
    end

    def site?
      role == 'site'
    end

    def site_code
      ENV.fetch('MAHIS_SITE_CODE') { raise 'MAHIS_SITE_CODE is not set' }
    end

    def central_url
      ENV.fetch('SITE_SYNC_CENTRAL_URL') { raise 'SITE_SYNC_CENTRAL_URL is not set' }
    end

    # The facility this site serves (a MaHIS location id): MAHIS_SITE_LOCATION_ID,
    # else MaHIS's own current_health_center_id setting. Its name is what
    # central shows for the site.
    def site_location_id
      ENV['MAHIS_SITE_LOCATION_ID'].presence ||
        ActiveRecord::Base.connection.select_value(
          "SELECT property_value FROM global_property WHERE property = 'current_health_center_id' LIMIT 1"
        ).presence
    end

    def secret
      ENV.fetch('SITE_SYNC_SECRET') { raise 'SITE_SYNC_SECRET is not set' }
    end

    # Mutual TLS client cert (see lib/tasks/site_sync_tls.rake). Optional: the
    # HMAC signature on every request already authenticates the site, so sync
    # keeps working with none of these set -- this adds transport-level
    # defense in depth once nginx is configured to terminate and verify it.
    def tls_cert_path
      ENV['SITE_SYNC_TLS_CERT'].presence
    end

    def tls_key_path
      ENV['SITE_SYNC_TLS_KEY'].presence
    end

    def tls_ca_path
      ENV['SITE_SYNC_TLS_CA'].presence
    end

    def mtls_enabled?
      tls_cert_path.present? && tls_key_path.present?
    end

    # Central only: reject any sync request whose TLS client cert (verified
    # and forwarded as a header by nginx; see prototype/site_sync/docker/
    # nginx-mtls/) does not match the claimed site. Off by default so the
    # HMAC-only prototype setup keeps working with no nginx in front.
    def mtls_required?
      ENV['SITE_SYNC_MTLS_REQUIRED'] == '1'
    end

    def admin_token
      ENV.fetch('SITE_SYNC_ADMIN_TOKEN', nil)
    end

    # The patient_identifier_type name that holds a patient's national ID,
    # used by DuplicateDetector to match patients across sites.
    def national_id_identifier_type_name
      ENV.fetch('SITE_SYNC_NATIONAL_ID_IDENTIFIER_TYPE', 'National ID')
    end

    # Key for encrypting sync_sites.secret at rest (see SecretCipher).
    # Falls back to the app's own secret_key_base so this works with no
    # extra config, but SITE_SYNC_SECRET_ENCRYPTION_KEY should be set
    # independently in production so rotating one doesn't require the other.
    def secret_cipher_key
      ENV['SITE_SYNC_SECRET_ENCRYPTION_KEY'].presence || Rails.application.secret_key_base
    end

    # MySQL account the capture triggers run as, e.g. 'mahis_sync'@'%'. It must
    # be able to INSERT into sync_change_log and hold TRIGGER on the synced
    # tables (rake site_sync:grants gives the sync user both).
    def trigger_definer
      ENV['SITE_SYNC_TRIGGER_DEFINER'].presence
    end

    # Max events per batch and max raw bytes per batch.
    def batch_max_events
      Integer(ENV.fetch('SITE_SYNC_BATCH_EVENTS', 1000))
    end

    def batch_max_bytes
      Integer(ENV.fetch('SITE_SYNC_BATCH_BYTES', 1_000_000))
    end

    # Events from a site whose clock runs further ahead of central than this
    # are refused, so a wrong server clock cannot win every conflict.
    def max_clock_ahead_us
      Integer(ENV.fetch('SITE_SYNC_MAX_CLOCK_AHEAD_S', 300)) * 1_000_000
    end
  end
end
