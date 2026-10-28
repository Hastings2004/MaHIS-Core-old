# frozen_string_literal: true

# Two-way site <-> central sync (prototype). Off unless MAHIS_SYNC_ROLE is set.
# Development logs every SQL statement, including whole sync payloads, which
# slows batch ingest badly; the prototype nodes run at SITE_SYNC_LOG_LEVEL.
Rails.logger.level = ENV['SITE_SYNC_LOG_LEVEL'].to_sym if ENV['MAHIS_SYNC_ROLE'] && ENV['SITE_SYNC_LOG_LEVEL'].present?

# Tags background-job-caused captures with their job name/id, same as
# tag_sync_request does for request-caused ones. Central needs this too now
# that its own local edits are captured and published (see LocalPublisher).
if %w[site central].include?(ENV['MAHIS_SYNC_ROLE'])
  Sidekiq.configure_server do |config|
    config.server_middleware do |chain|
      chain.add SiteSync::SidekiqTagger
    end
  end
end
