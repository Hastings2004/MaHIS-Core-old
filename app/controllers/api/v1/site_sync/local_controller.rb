# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # Site-side views for logged-in users: what one API request changed, and
      # this site's sync status.
      class LocalController < ::ApplicationController
        # GET /api/v1/site_sync/requests/:request_id
        # Every captured change made by one API request, and where it is now.
        def request_changes
          changes = ActiveRecord::Base.lease_connection.select_all(<<~SQL).to_a
            SELECT l.id, l.table_name, l.operation, l.row_uuid, l.endpoint, l.user_uuid, l.captured_at,
                   b.priority, b.batch_number AS batch_seq, COALESCE(b.status, 'unsealed') AS sync_status, b.acknowledged_at
            FROM sync_change_log l LEFT JOIN sync_batches b ON b.id = l.batch_id
            WHERE l.request_id = #{ActiveRecord::Base.lease_connection.quote(params[:request_id])}
            ORDER BY l.id
          SQL
          render json: { request_id: params[:request_id], changes: }
        end

        # GET /api/v1/site_sync/status
        def status
          heartbeat = ::SiteSync::Heartbeat.new(client: nil)
          notices = ActiveRecord::Base.lease_connection.select_all(<<~SQL).to_a
            SELECT change_key, table_name, row_uuid, reason, details, status, created_at
            FROM sync_quarantine_notices WHERE status = 'open' ORDER BY id DESC LIMIT 100
          SQL
          render json: heartbeat.status.merge('quarantine' => notices)
        end
      end
    end
  end
end
