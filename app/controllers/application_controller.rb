# frozen_string_literal: true

require 'require_params'
require 'user_service'

class ApplicationController < ActionController::API
  around_action :clear_request_context
  before_action :refuse_while_sync_restoring
  # before_action :check_location
  before_action :authenticate
  before_action :set_audited_user
  around_action :tag_sync_request
  # before_action :check_client_version
  after_action  :refresh_dashboard, if: :refresh_dashboard_needed?
  after_action  :refresh_client_details, if: :refresh_client_details_needed?

  protected

  include RequireParams
  include ExceptionHandler

  CURRENT_LOCATION_PROPERTY = 'current_health_center_id'
  DEFAULT_PAGE_SIZE = 10

  # Map of clients to their allowed versions
  CLIENT_VERSION_CONFIGURATION = {
    'EMASTERCARD' => 'v2025.Q4.R0',
    'POC' => 'v2025.Q4.R0',
    'MAHIS' => '',
    'AETC' => ''
  }.freeze

  # Required by audited gem
  def current_user
    User.current
  end

  def set_audited_user
    # audited v5.8 calls .try!(:call) on whatever is stored here, so it must
    # be a Proc — storing the User object directly raises NoMethodError.
    Audited.store[:current_user] = -> { User.current }
    # Also read by LoginThrottleService when auditing failed logins, which has no
    # access to the request. NOTE: this is only the real client address if the
    # reverse proxy sets X-Forwarded-For.
    Audited.store[:current_remote_address] = request.remote_ip
  end

  def authenticate
    authentication_token = request.headers['Authorization']
    unless authentication_token
      errors = ['Authorization token required']
      render json: { errors: }, status: :unauthorized
      return false
    end

    user = UserService.authenticate authentication_token
    unless user
      errors = ['Invalid or expired authentication token']
      render json: { errors: }, status: :unauthorized
      return false
    end

    User.current = user
    Location.current = user.location
    true
  end

  def check_location
    location_id = GlobalProperty.unscoped.where(property: CURRENT_LOCATION_PROPERTY).first.property_value
    unless location_id
      render json: { errors: ['Current location not set'] }, status: :service_unavailable
      return false
    end

    Location.current = Location.find(location_id)
    true
  end

  def paginate(queryset)
    params.permit(:paginate, :page, :page_size)
    return queryset.all if params[:paginate] == 'false'

    limit = (params[:page_size] || DEFAULT_PAGE_SIZE).to_i
    offset = ((params[:page] || 1).to_i - 1) * limit

    queryset.offset(offset).limit(limit)
  end

  def parse_date(str_date)
    Date.strptime(str_date)
  rescue ArgumentError => e
    render json: { errors: ["Failed to parse date: #{e}"] },
           status: :bad_request
    nil
  end

  def render_zpl(data)
    raw = params.permit(:raw)[:raw]

    unless raw && raw == 'true'
      render json: data

      return
    end

    send_data data[:zpl], type: 'application/label; charset=utf-8',
                          stream: false,
                          filename: "barcode-#{rand(10_000)}.lbl",
                          disposition: 'inline'
  end

  # Takes search filters and converts them to an expression containing
  # inexact glob matchers that can be passed to `where` expressins.
  def make_inexact_filters(filters, fields = nil)
    fields ||= filters.keys

    inexact_filters = filters.to_hash.each_with_object([[], []]) do |kv_pair, inexact_filters|
      k, v = kv_pair

      if fields.include? k.to_sym
        inexact_filters[0] << "#{k} like ?"
        inexact_filters[1] << "%#{v}%"
      else
        inexact_filters[0] << "#{k} = ?"
        inexact_filters[1] << v
      end
    end

    [inexact_filters[0].join(' AND ')] + inexact_filters[1]
  end

  private

  def clear_request_context
    yield
  ensure
    User.current = nil
    Location.current = nil
    Audited.store[:current_user] = nil if defined?(Audited)
  end

  # Two-way sync: tag every change this request makes with the endpoint,
  # request id and user, so central can trace rows back to the call that
  # produced them.
  def tag_sync_request(&)
    # Config.enabled?, not site? -- central's own capture triggers need the
    # same request_id/endpoint/user tagging a site's do, now that central's
    # local edits are captured and published too (see SiteSync::LocalPublisher).
    return yield unless SiteSync::Config.enabled?

    SiteSync::Context.tag(request_id: request.request_id, endpoint: "#{request.request_method} #{request.path}",
                          user_uuid: User.current&.uuid, &)
  end

  # While this site is being rebuilt from central, nobody may log in or save.
  def refuse_while_sync_restoring
    return unless SiteSync::Config.site? && SiteSync::State.restoring?

    render json: { errors: ['This site is being restored from the central backup. Please wait.'] },
           status: :service_unavailable
  end

  def check_client_version
    return true if params[:no_client]

    client = request.headers['Client']
    client_version = request.headers['Client-Version']

    unless client
      render json: { errors: ['Unrecognized API Client'] }, status: :bad_request
      return false
    end

    unless client_version
      render json: { errors: ['Unknown API Client Version'] }, status: :bad_request
      return false
    end

    if CLIENT_VERSION_CONFIGURATION.key?(client)
      required_version = CLIENT_VERSION_CONFIGURATION[client]

      return true unless required_version

      unless validate_frontend_versions(client_version, required_version)
        render json: { errors: ["Minimum version required is #{required_version}"], required_version: required_version },
               status: :upgrade_required
        return false
      end
    end
    true
  end

  def validate_frontend_versions(active, target)
    to_num = ->(str) { str.gsub(/\D/, '').to_i }

    active_version_parts = active.split('.')
    target_version_parts = target.split('.')

    active_version_year = to_num.call(active_version_parts[0])
    active_version_quarter = to_num.call(active_version_parts[1])
    active_version_revision = to_num.call(active_version_parts[2])

    target_version_year = to_num.call(target_version_parts[0])
    target_version_quarter = to_num.call(target_version_parts[1])
    target_version_revision = to_num.call(target_version_parts[2])

    return false if active_version_year < target_version_year
    return false if active_version_quarter < target_version_quarter
    return false if active_version_revision < target_version_revision

    true
  end

  def refresh_dashboard
    today = Date.today
    ImmunizationReportJob.perform_later(today.beginning_of_year.to_s, today.to_s, User.current.location_id)
  end

  def refresh_dashboard_needed?
    patient_programs_create_action? || administer_vaccine_action? || orders_destroy_action?
  end

  def patient_programs_create_action?
    controller_name == 'patient_programs' && action_name == 'create'
  end

  def administer_vaccine_action?
    controller_name == 'administer_vaccine' && action_name == 'administer_vaccine'
  end

  def orders_destroy_action?
    controller_name == 'orders' && action_name == 'destroy'
  end

  def refresh_client_details
    ClientDetailsJob.perform_later(User.current.location_id)
  end

  def refresh_client_details_needed?
    patient_create_action?
  end

  def patient_create_action?
    controller_name == 'patients' && action_name == 'create'
  end
end
