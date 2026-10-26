# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # Central -> site: the subscribed change feed and on-demand patient fetch.
      class FeedController < BaseController
        HYDRATE_REASONS = %w[referral transfer national_id_lookup].freeze
        HYDRATE_PER_HOUR = Integer(ENV.fetch('SITE_SYNC_HYDRATE_PER_HOUR', 200))

        # GET /api/v1/site_sync/changes?cursor=<global_seq>&limit=<n>
        # Changes after the cursor for patients this site follows, plus
        # corrections addressed to it; never the site's own changes.
        def changes
          cursor = params[:cursor].to_i
          limit = params.fetch(:limit, 500).to_i.clamp(1, 2000)
          events = nil
          next_cursor = nil
          connection.transaction(isolation: :repeatable_read) do
            rows = connection.select_all(<<~SQL).to_a
              SELECT l.global_seq, l.change_json FROM sync_central_feed l
              WHERE l.global_seq > #{cursor}
                AND (l.for_site = #{q(site_code)}
                     OR (l.for_site IS NULL AND l.from_site <> #{q(site_code)}
                         AND l.patient_uuid IN (SELECT s.patient_uuid FROM sync_subscriptions s
                                                WHERE s.site_code = #{q(site_code)})))
              ORDER BY l.global_seq LIMIT #{limit}
            SQL
            events = rows.map { |r| { 'global_seq' => r['global_seq'], 'event' => JSON.parse(r['change_json']) } }
            # Short page: everything up to the newest committed change has been
            # seen, matching or not, so the cursor can jump to it.
            next_cursor = if rows.size == limit
                            rows.last['global_seq']
                          else
                            [connection.select_value('SELECT COALESCE(MAX(global_seq), 0) FROM sync_central_feed').to_i, cursor].max
                          end
          end
          render json: { events:, next_cursor: }
        end

        # POST /api/v1/site_sync/patients/hydrate { uuid | identifier, reason }
        def hydrate
          reason = payload['reason'].to_s
          unless HYDRATE_REASONS.include?(reason)
            return render json: { status: 'refused', error: 'reason_required', allowed: HYDRATE_REASONS },
                          status: :unprocessable_entity
          end

          recent = connection.select_value(<<~SQL).to_i
            SELECT COUNT(*) FROM sync_subscriptions
            WHERE site_code = #{q(site_code)} AND reason <> 'own' AND created_at > NOW(6) - INTERVAL 1 HOUR
          SQL
          return render json: { status: 'refused', error: 'rate_limited' }, status: :too_many_requests if recent >= HYDRATE_PER_HOUR

          uuid = payload['uuid'] || find_by_identifier(payload['identifier'])
          return render json: { status: 'refused', error: 'patient_not_found' }, status: :not_found unless uuid

          events = ::SiteSync::Central.with_feed_lock do
            connection.transaction do
              ::SiteSync::Central.subscribe(site_code, uuid, reason)
              ::SiteSync::Central.alert(site_code, 'patient_fetch', "Fetched patient #{uuid} (#{reason})")
              ::SiteSync::PatientRecord.new(connection).events(uuid)
            end
          end
          render json: { patient_uuid: uuid, change_count: events.size, events: }
        end

        private

        def find_by_identifier(identifier)
          return nil if identifier.blank?

          connection.select_value(<<~SQL)
            SELECT p.uuid FROM patient_identifier i JOIN person p ON p.person_id = i.patient_id
            WHERE i.identifier = #{q(identifier)} AND i.voided = 0 LIMIT 1
          SQL
        end
      end
    end
  end
end
