# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # Endpoints a site's sync agent calls on central. They authenticate the
      # site (HMAC signature with the site's secret), not a user, so they do
      # not inherit ApplicationController's user login.
      class BaseController < ActionController::API
        # How long accepted request nonces are remembered (see HeartbeatsController).
        NONCE_DAYS = 90

        before_action :require_central
        before_action :authenticate_site

        rescue_from JSON::ParserError do
          render json: { status: 'refused', error: 'invalid_json' }, status: :bad_request
        end

        protected

        attr_reader :site

        def site_code
          site['site_code']
        end

        def payload
          @payload ||= request.raw_post.present? ? JSON.parse(request.raw_post) : {}
        end

        def connection
          ActiveRecord::Base.lease_connection
        end

        def q(value)
          connection.quote(value)
        end

        private

        def require_central
          return if ::SiteSync::Config.central?

          render json: { status: 'refused', error: 'not_central' }, status: :not_found
        end

        def authenticate_site
          @site = ::SiteSync::Central.site(request.headers['X-Site-Code'].to_s)

          if ::SiteSync::Config.mtls_required?
            verified_cn = request.headers['X-Site-Code-Verified'].to_s
            if verified_cn.blank? || verified_cn != request.headers['X-Site-Code'].to_s
              ::SiteSync::Central.alert(site_code, 'mtls_mismatch',
                                        "TLS client cert CN (#{verified_cn.presence || 'none'}) does not match the " \
                                        "claimed site (#{request.headers['X-Site-Code']})") if @site
              return render json: { status: 'refused', error: 'mtls_required' }, status: :unauthorized
            end
          end

          timestamp = request.headers['X-Site-Timestamp'].to_s
          nonce = request.headers['X-Site-Nonce'].to_s
          expected = @site && nonce.present? &&
                     ::SiteSync::Client.signature(::SiteSync::Central.secret_for(@site), request.method, request.fullpath,
                                                  timestamp, nonce, request.raw_post)
          given = request.headers['X-Site-Signature'].to_s
          unless expected && ActiveSupport::SecurityUtils.secure_compare(expected, given)
            if @site
              ::SiteSync::Central.alert(@site['site_code'], 'bad_signature',
                                        "Refused #{request.method} #{request.path}: signature does not match the site's " \
                                        'current secret (old or revoked server?)')
            end
            return render json: { status: 'refused', error: 'unauthenticated' }, status: :unauthorized
          end

          # Each signed request is accepted once. There is deliberately no
          # tight time window: a site whose clock runs ahead must still be able
          # to sync (CentralIngest caps its clock). But nonces are only kept for
          # NONCE_DAYS, so anything signed longer ago than that is refused, or
          # it could be replayed once its nonce is forgotten.
          if timestamp.to_i < ::SiteSync::Hlc.now_us - (NONCE_DAYS - 1) * 86_400 * 1_000_000
            ::SiteSync::Central.alert(site_code, 'stale_request',
                                      "Refused a request signed more than #{NONCE_DAYS - 1} days ago " \
                                      '(a replay, or a site clock far behind)')
            return render json: { status: 'refused', error: 'stale_request' }, status: :unauthorized
          end
          connection.execute(<<~SQL)
            INSERT INTO sync_request_nonces (nonce, site_code, signed_at_us, seen_at)
            VALUES (#{q(nonce)}, #{q(site_code)}, #{q(timestamp.to_i)}, NOW(6))
          SQL
        rescue ActiveRecord::RecordNotUnique
          ::SiteSync::Central.alert(site_code, 'replayed_request', "Refused a repeated request: #{request.method} #{request.path}")
          render json: { status: 'refused', error: 'replayed' }, status: :unauthorized
        end
      end
    end
  end
end
