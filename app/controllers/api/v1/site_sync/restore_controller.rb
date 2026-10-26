# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # Serves central's backup copy of a site to its replacement server.
      # Only available while the site is frozen for restore.
      class RestoreController < BaseController
        before_action :require_restoring

        # GET /api/v1/site_sync/restore/manifest
        def manifest
          tables = ::SiteSync::Config.table_names.index_with do |table|
            digests = ::SiteSync::Merkle.mirror_digests(connection, site_code, table, 2)
            digest = ::SiteSync::Merkle.table_digest(digests)
            { 'count' => digest.split(':').first.to_i, 'digest' => digest }
          end
          render json: {
            server_generation: site['server_generation'].to_i,
            restore_from_global_seq: site['restore_from_global_seq'].to_i,
            last_received_at: connection.select_value(
              "SELECT MAX(received_at) FROM sync_received_batches WHERE site_code = #{q(site_code)}"
            )&.iso8601,
            max_change_time: connection.select_value(
              "SELECT COALESCE(MAX(change_time), 0) FROM sync_site_backup WHERE site_code = #{q(site_code)}"
            ).to_i,
            tables:
          }
        end

        # GET /api/v1/site_sync/restore/export?table=&after_id=&limit=
        # Resumable: the caller passes the last local id it received.
        def export
          table = params[:table].to_s
          unless ::SiteSync::Config.synced?(table)
            return render json: { status: 'refused', error: 'unknown_table' }, status: :unprocessable_entity
          end

          limit = params.fetch(:limit, 2000).to_i.clamp(1, 10_000)
          rows = connection.select_rows(<<~SQL)
            SELECT local_id, row_json FROM sync_site_backup
            WHERE site_code = #{q(site_code)} AND table_name = #{q(table)} AND deleted = 0
              AND local_id > #{params[:after_id].to_i}
            ORDER BY local_id LIMIT #{limit}
          SQL
          render json: { rows: rows.map { |_, json| JSON.parse(json) }, last_id: rows.last&.first }
        end

        # POST /api/v1/site_sync/restore/complete { tables: { name => checksum_ok } }
        def complete
          failed = (payload['tables'] || {}).reject { |_, ok| ok }.keys
          return render json: { status: 'refused', error: 'checksum_failed', tables: failed }, status: :conflict if failed.any?

          connection.execute(<<~SQL)
            UPDATE sync_sites SET status = 'active', updated_at = NOW(6) WHERE site_code = #{q(site_code)}
          SQL
          ::SiteSync::Central.alert(site_code, 'restore_complete', "Site restored and verified in server generation #{site['server_generation']}")
          render json: { status: 'active', server_generation: site['server_generation'].to_i }
        end

        private

        def require_restoring
          return if site['status'] == 'restoring'

          render json: { status: 'refused', error: 'site_not_restoring' }, status: :conflict
        end
      end
    end
  end
end
