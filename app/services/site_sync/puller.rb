# frozen_string_literal: true

module SiteSync
  # Central -> site. Pulls the changes this site is subscribed to and applies
  # them; the cursor moves in the same transaction as the data, so a crash
  # mid-page simply re-pulls the page.
  class Puller
    attr_reader :stats

    def initialize(client: Client.new)
      @client = client
      @conn = ActiveRecord::Base.lease_connection
      @applier = DownstreamApplier.new(@conn)
      @stats = Hash.new(0)
    end

    # Returns :idle, :applied or :offline.
    def run_once(limit: 500, max_pages: 100)
      applied = false
      max_pages.times do
        cursor = State.get_i('pull_cursor', 0)
        response = @client.get('/api/v1/site_sync/changes', cursor:, limit:)
        @stats[:bytes_received] += response.bytes_received
        raise "Pull refused: HTTP #{response.status} #{response.body}" unless response.status == 200

        items = response.body['events']
        @conn.transaction do
          items.each { |item| apply_one(item['event'], item['global_seq']) }
          State.set('pull_cursor', response.body['next_cursor'])
        end
        applied ||= items.any?
        break if items.size < limit
      end
      retry_pending
      applied ? :applied : :idle
    rescue Client::Unreachable
      :offline
    end

    # Fetch one patient's full record from central (a referral or a walk-in
    # from another facility). This also subscribes the site to the patient,
    # so later changes arrive with the regular pull.
    def hydrate(reason:, uuid: nil, identifier: nil)
      response = @client.post('/api/v1/site_sync/patients/hydrate', { uuid:, identifier:, reason: }.compact)
      raise "Hydrate refused: HTTP #{response.status} #{response.body}" unless response.status == 200

      @conn.transaction do
        response.body['events'].each { |event| apply_one(event, nil) }
      end
      retry_pending
      response.body.slice('patient_uuid', 'change_count')
    end

    # A parked row whose parent never arrives is not retried forever: after
    # this many attempts or this many days it is marked orphaned, counted in
    # the heartbeat and shown on central's dashboard for a data officer.
    MAX_PENDING_ATTEMPTS = 100
    MAX_PENDING_DAYS = 7

    def retry_pending
      @conn.select_all('SELECT * FROM sync_waiting_changes WHERE orphaned_at IS NULL ORDER BY id').to_a.each do |row|
        @conn.transaction(requires_new: true) do
          @applier.apply(JSON.parse(row['change_json']))
          @conn.execute("DELETE FROM sync_waiting_changes WHERE id = #{row['id']}")
          @stats[:pending_applied] += 1
        end
      rescue Codec::MissingRef, ActiveRecord::StatementInvalid => e
        @conn.execute(<<~SQL)
          UPDATE sync_waiting_changes
          SET attempts = attempts + 1, last_error = #{@conn.quote(e.message.slice(0, 500))},
              orphaned_at = IF(attempts >= #{MAX_PENDING_ATTEMPTS}
                               OR created_at < NOW(6) - INTERVAL #{MAX_PENDING_DAYS} DAY, NOW(6), NULL)
          WHERE id = #{row['id']}
        SQL
      end
    end

    private

    def apply_one(event, global_seq)
      @conn.transaction(requires_new: true) do
        @stats[@applier.apply(event)] += 1
      end
    rescue Codec::MissingRef, ActiveRecord::StatementInvalid => e
      # Its parent row has not arrived yet (or is held in quarantine at
      # central): park it and retry after every pull.
      @conn.execute(<<~SQL)
        INSERT INTO sync_waiting_changes (global_seq, table_name, row_uuid, change_json, attempts, last_error, created_at)
        VALUES (#{@conn.quote(global_seq)}, #{@conn.quote(event['table'])}, #{@conn.quote(event['uuid'])},
                #{@conn.quote(event.to_json)}, 1, #{@conn.quote(e.message.slice(0, 500))}, NOW(6))
      SQL
      @stats[:parked] += 1
    end
  end
end
