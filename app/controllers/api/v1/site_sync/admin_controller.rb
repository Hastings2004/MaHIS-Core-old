# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # Central administration: register sites, freeze a site for restore,
      # review quarantine, and the sync dashboard. Protected by
      # SITE_SYNC_ADMIN_TOKEN (header X-Admin-Token, or ?token= for the
      # dashboard in a browser).
      class AdminController < ActionController::API
        include ActionController::MimeResponds

        before_action :require_admin

        # GET /api/v1/site_sync/admin/locations?q=<name> -- for the register-a-site
        # search box. Returns the location's uuid, never its sequential
        # integer id: an admin should not need to know or type that, and a
        # client-facing auto-increment id is worth avoiding on its own.
        def locations
          term = params[:q].to_s.strip
          return render json: [] if term.length < 2

          rows = connection.select_all(<<~SQL).to_a
            SELECT uuid, name, city_village FROM location
            WHERE retired = 0 AND name LIKE #{q("%#{term}%")}
            ORDER BY (name LIKE #{q("#{term}%")}) DESC, name
            LIMIT 20
          SQL
          render json: rows
        end

        # POST /api/v1/site_sync/admin/sites { site_code, location_uuid }
        # The name is not taken from the request: it comes from the
        # resolved location, same as the dashboard derives it, so a site's
        # registered name can never drift from its actual facility.
        def register
          site_code = params.require(:site_code)
          # Reserved: Central.publish uses this literal as from_site for its
          # own captured changes (see SiteSync::LocalPublisher). A real site
          # registering under it would collide with central's own entries.
          if site_code.to_s.upcase == ::SiteSync::LocalPublisher::SITE_CODE
            return render json: { error: 'reserved_site_code', code: ::SiteSync::LocalPublisher::SITE_CODE },
                          status: :unprocessable_entity
          end

          location_uuid = params.require(:location_uuid)
          location = connection.select_one("SELECT location_id, name FROM location WHERE uuid = #{q(location_uuid)}")
          return render json: { error: 'unknown_location' }, status: :unprocessable_entity unless location

          secret = SecureRandom.hex(32)
          ::SiteSync::Central.register_site(site_code, name: location['name'], secret:, location_id: location['location_id'])
          render json: { site_code:, location_id: location['location_id'], name: location['name'], secret: }
        end

        # POST /api/v1/site_sync/admin/sites/:code/freeze
        # Step 1-2 of a restore: stop the old server (its secret is replaced)
        # and open a new server generation for the replacement.
        def freeze
          site = ::SiteSync::Central.site(params[:code])
          return render json: { error: 'unknown_site' }, status: :not_found unless site

          secret = SecureRandom.hex(32)
          ::SiteSync::Central.with_feed_lock do
            connection.execute(<<~SQL)
              UPDATE sync_sites SET status = 'restoring', server_generation = server_generation + 1, secret = #{q(::SiteSync::SecretCipher.encrypt(secret))},
                restore_from_global_seq = (SELECT COALESCE(MAX(global_seq), 0) FROM sync_central_feed), updated_at = NOW(6)
              WHERE site_code = #{q(params[:code])}
            SQL
          end
          site = ::SiteSync::Central.site(params[:code])
          ::SiteSync::Central.alert(params[:code], 'frozen',
                                    "Frozen for restore; server generation #{site['server_generation']} opened and the old server's secret revoked")
          render json: { site_code: params[:code], server_generation: site['server_generation'].to_i, secret:,
                         restore_from_global_seq: site['restore_from_global_seq'].to_i }
        end

        # GET /api/v1/site_sync/admin/quarantine
        def quarantine
          render json: connection.select_all(<<~SQL).to_a
            SELECT id, site_code, table_name, row_uuid, reason, details, waiting_for_uuid, request_id, status, created_at
            FROM sync_quarantine ORDER BY id DESC LIMIT 200
          SQL
        end

        # POST /api/v1/site_sync/admin/quarantine/:id/release
        # A data officer has fixed the cause (for example added the missing
        # reference data): apply the record and anything parked behind it.
        def release
          item = connection.select_one("SELECT * FROM sync_quarantine WHERE id = #{params[:id].to_i}")
          return render json: { error: 'not_found' }, status: :not_found unless item

          outcome = ::SiteSync::CentralIngest.new(item['site_code']).release(item)
          render json: outcome
        end

        # POST /api/v1/site_sync/admin/quarantine/:id/reject
        def reject
          connection.execute(<<~SQL)
            UPDATE sync_quarantine SET status = 'rejected', resolved_at = NOW(6) WHERE id = #{params[:id].to_i}
          SQL
          head :no_content
        end

        # GET /api/v1/site_sync/admin/conflicts
        def conflicts
          render json: connection.select_all(
            'SELECT * FROM sync_conflicts ORDER BY id DESC LIMIT 200'
          ).to_a
        end

        # GET /api/v1/site_sync/admin/duplicates
        def duplicates
          render json: connection.select_all(
            "SELECT * FROM sync_duplicate_candidates WHERE status = 'open' ORDER BY id DESC LIMIT 200"
          ).to_a
        end

        # POST /api/v1/site_sync/admin/duplicates/:id/dismiss
        # A data officer has checked and these are two different people.
        # Linking a genuine duplicate's clinical history is not implemented
        # here -- it is a "central decision" of its own (design section 3).
        def dismiss_duplicate
          connection.execute(<<~SQL)
            UPDATE sync_duplicate_candidates SET status = 'dismissed', resolved_at = NOW(6) WHERE id = #{params[:id].to_i}
          SQL
          head :no_content
        end

        # POST /api/v1/site_sync/admin/corrections { table, uuid, changes: {col: value, ...}, reason }
        # A data officer's judgment call on a field normal sync never
        # auto-resolves (national id, sex, birth date, death status) or any
        # other row that needs a central-issued fix, sent to every site that
        # has this patient.
        def correct
          result = ::SiteSync::CentralCorrection.new(connection).apply(
            table: params.require(:table), uuid: params.require(:uuid),
            changes: params.require(:changes).to_unsafe_h, reason: params[:reason]
          )
          render json: result
        rescue ::SiteSync::CentralCorrection::InvalidCorrection => e
          render json: { error: 'invalid_correction', details: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/site_sync/admin/dashboard(.json)
        def dashboard
          data = ::SiteSync::Dashboard.new(connection).data
          respond_to do |format|
            format.json { render json: data }
            format.any { render html: ::SiteSync::Dashboard.html(data).html_safe, content_type: 'text/html' }
          end
        end

        private

        def require_admin
          token = request.headers['X-Admin-Token'].presence || params[:token]
          expected = ::SiteSync::Config.admin_token
          return if ::SiteSync::Config.central? && expected.present? && token.present? &&
                    ActiveSupport::SecurityUtils.secure_compare(expected, token)

          render json: { error: 'unauthorized' }, status: :unauthorized
        end

        def connection
          ActiveRecord::Base.lease_connection
        end

        def q(value)
          connection.quote(value)
        end
      end
    end
  end
end
