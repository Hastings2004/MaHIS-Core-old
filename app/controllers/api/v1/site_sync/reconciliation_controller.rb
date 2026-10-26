# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # Central's side of nightly reconciliation: compares the site's digests
      # with central's backup copy of that site, and serves rows for repair.
      class ReconciliationController < BaseController
        before_action :require_synced_table, only: %i[merkle rows mirror_rows]

        # POST /api/v1/site_sync/merkle { table, prefix_len, within, digests }
        def merkle
          ours = ::SiteSync::Merkle.mirror_digests(connection, site_code, table, payload['prefix_len'].to_i, payload['within'])
          render json: { differing: ::SiteSync::Merkle.differing(payload['digests'] || {}, ours) }
        end

        # POST /api/v1/site_sync/merkle/rows { table, prefixes, rows: { uuid => hash } }
        def rows
          prefixes = Array(payload['prefixes'])
          ours = connection.select_rows(<<~SQL).to_h
            SELECT row_uuid, row_hash FROM sync_site_backup
            WHERE site_code = #{q(site_code)} AND table_name = #{q(table)} AND deleted = 0
              AND LEFT(row_uuid, 4) IN (#{prefixes.map { |p| q(p) }.join(', ').presence || 'NULL'})
          SQL
          theirs = payload['rows'] || {}
          render json: {
            site_only: theirs.keys - ours.keys,
            central_only: ours.keys - theirs.keys,
            different: (theirs.keys & ours.keys).reject { |uuid| theirs[uuid] == ours[uuid] }
          }
        end

        # POST /api/v1/site_sync/mirror_rows { table, uuids }
        def mirror_rows
          uuids = Array(payload['uuids']).first(5000)
          rows = connection.select_rows(<<~SQL).map { |uuid, json| { 'uuid' => uuid, 'row' => JSON.parse(json) } }
            SELECT row_uuid, row_json FROM sync_site_backup
            WHERE site_code = #{q(site_code)} AND table_name = #{q(table)} AND deleted = 0
              AND row_uuid IN (#{uuids.map { |u| q(u) }.join(', ').presence || 'NULL'})
          SQL
          render json: { rows: }
        end

        # POST /api/v1/site_sync/reconciliation_report: the site's summary,
        # kept at central for the dashboard.
        def report
          connection.execute(<<~SQL)
            INSERT INTO sync_reconciliation_runs (site_code, status, report_json, bytes_exchanged, started_at, finished_at)
            VALUES (#{q(site_code)}, #{q(payload['status'])}, #{q(payload.to_json)}, #{payload['bytes_exchanged'].to_i},
                    NOW(6), NOW(6))
          SQL
          held = (payload['tables'] || {}).sum { |_, t| Array(t['held_for_review']).size }
          if held.positive?
            ::SiteSync::Central.alert(site_code, 'reconciliation_review',
                                      "#{held} row(s) differ between the site and central's copy; a data officer must " \
                                      'choose which is right per row (rake site_sync:reconcile ' \
                                      'REPAIR_CENTRAL=uuid,... or REPAIR_SITE=uuid,...)')
          end
          last_two = connection.select_values(<<~SQL)
            SELECT report_json FROM sync_reconciliation_runs WHERE site_code = #{q(site_code)} ORDER BY id DESC LIMIT 2
          SQL
          if last_two.size == 2 && last_two.all? { |json| differences(JSON.parse(json)).positive? }
            ::SiteSync::Central.alert(site_code, 'reconciliation_repeat',
                                      'Mismatches found on two runs in a row: investigate the site server')
          end
          head :no_content
        end

        private

        def differences(report)
          (report['tables'] || {}).values.sum { |t| t['differences'].to_i }
        end

        def table
          payload['table']
        end

        def require_synced_table
          return if ::SiteSync::Config.synced?(table.to_s)

          render json: { status: 'refused', error: 'unknown_table' }, status: :unprocessable_entity
        end
      end
    end
  end
end
