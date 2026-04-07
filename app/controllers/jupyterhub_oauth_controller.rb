require 'json'
require 'net/http'
require 'securerandom'
require 'uri'

# JupyterHub OAuth login controller
class JupyterhubOauthController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[start callback failure]

  JUPYTERHUB_PROVIDER = 'jupyterhub'.freeze

  def start
    return redirect_to(stored_return_to_or(root_path)) if user_signed_in?
    return render_not_configured unless jupyterhub_oauth_enabled?

    session[:jupyterhub_oauth_state] = SecureRandom.hex(32)
    session[:jupyterhub_oauth_return_to] = sanitized_return_to(params[:return_to] || request.referer)

    redirect_to authorize_url_for(session[:jupyterhub_oauth_state]), allow_other_host: true
  end

  def callback
    return render_not_configured unless jupyterhub_oauth_enabled?
    return redirect_with_error('JupyterHub login was denied.') if params[:error].present?
    return redirect_with_error('Missing OAuth code from JupyterHub.') if params[:code].blank?

    expected_state = session.delete(:jupyterhub_oauth_state)
    if expected_state.blank? || expected_state != params[:state]
      return redirect_with_error('Invalid JupyterHub login state.')
    end

    token_response = exchange_code_for_token(params[:code])
    access_token = token_response.fetch('access_token')
    hub_user = fetch_hub_user(access_token)
    user = find_or_create_user_from_jupyterhub!(hub_user)

    if GalleryConfig.registration.require_admin_approval && !user.approved?
      return redirect_with_error('Your account has been registered, but an administrator has not yet approved it.')
    end

    sign_in(:user, user)
    redirect_to stored_return_to_or(root_path)
  rescue KeyError => e
    redirect_with_error("Invalid JupyterHub OAuth response: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("JupyterHub OAuth failed: #{e.class}: #{e.message}")
    redirect_with_error('JupyterHub login failed.')
  end

  def failure
    redirect_with_error('JupyterHub login failed.')
  end

  private

  def render_not_configured
    respond_to do |format|
      format.html do
        redirect_to new_user_session_path, alert: 'JupyterHub login is not configured.'
      end
      format.json do
        render json: { message: 'JupyterHub login is not configured.' }, status: :service_unavailable
      end
    end
  end

  def redirect_with_error(message)
    redirect_to new_user_session_path, alert: message
  end

  def stored_return_to_or(fallback)
    session.delete(:jupyterhub_oauth_return_to).presence || fallback
  end

  def sanitized_return_to(candidate)
    return nil if candidate.blank?

    uri = URI.parse(candidate)
    return candidate if uri.host.nil? && candidate.start_with?('/')
    return candidate if uri.host == request.host && uri.scheme == request.scheme

    nil
  rescue URI::InvalidURIError
    nil
  end

  def authorize_url_for(state)
    query = {
      client_id: jupyterhub_client_id,
      redirect_uri: jupyterhub_oauth_callback_url,
      response_type: 'code',
      state: state
    }
    query[:scope] = jupyterhub_scopes.join(' ') if jupyterhub_scopes.any?
    "#{jupyterhub_authorize_url}?#{Rack::Utils.build_query(query)}"
  end

  def exchange_code_for_token(code)
    uri = URI.parse(jupyterhub_token_url)
    request = Net::HTTP::Post.new(uri)
    request.set_form_data(
      grant_type: 'authorization_code',
      code: code,
      client_id: jupyterhub_client_id,
      client_secret: jupyterhub_client_secret,
      redirect_uri: jupyterhub_oauth_callback_url
    )

    response = perform_http_request(uri, request)
    parse_json_response(response, 'token exchange')
  end

  def fetch_hub_user(access_token)
    uri = URI.parse(jupyterhub_user_url)
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "token #{access_token}"

    response = perform_http_request(uri, request)
    parse_json_response(response, 'user lookup')
  end

  def perform_http_request(uri, request)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end
  end

  def parse_json_response(response, action)
    unless response.is_a?(Net::HTTPSuccess)
      raise "JupyterHub #{action} failed with status #{response.code}"
    end

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    raise "JupyterHub #{action} returned invalid JSON: #{e.message}"
  end

  def find_or_create_user_from_jupyterhub!(hub_user)
    uid = extract_hub_uid(hub_user)
    identity = Identity.find_by(provider: JUPYTERHUB_PROVIDER, uid: uid)
    user = identity&.user || find_existing_local_user(hub_user, uid) || create_local_user_from_hub!(hub_user, uid)

    link_identity!(user, uid)
    sync_user_from_hub!(user, hub_user, uid)
    user
  end

  def find_existing_local_user(hub_user, uid)
    email = extract_claim(hub_user, jupyterhub_email_claims)
    user = User.find_by(email: email) if email.present? && jupyterhub_link_existing_by_email?
    user ||= User.find_by(user_name: normalize_jupyterhub_username(uid)) if jupyterhub_link_existing_by_username?
    user
  end

  def create_local_user_from_hub!(hub_user, uid)
    email = extract_claim(hub_user, jupyterhub_email_claims)
    email ||= fallback_email_for(uid)
    raise 'JupyterHub user did not provide an email address.' if email.blank?

    attrs = {
      email: email,
      password: Devise.friendly_token[0, 20],
      confirmed_at: Time.now.utc,
      confirmation_token: nil,
      first_name: extract_first_name(hub_user),
      last_name: extract_last_name(hub_user),
      user_name: unique_user_name_for(uid)
    }
    attrs[:approved] = !GalleryConfig.registration.require_admin_approval
    User.create!(attrs)
  end

  def sync_user_from_hub!(user, hub_user, uid)
    attrs = {}

    email = extract_claim(hub_user, jupyterhub_email_claims)
    attrs[:email] = email if email.present? && user.email != email

    first_name = extract_first_name(hub_user)
    attrs[:first_name] = first_name if first_name.present? && user.first_name != first_name

    last_name = extract_last_name(hub_user)
    attrs[:last_name] = last_name if last_name.present? && user.last_name != last_name

    attrs[:user_name] = unique_user_name_for(uid, user) if user.user_name.blank?

    user.update!(attrs) if attrs.any?
  end

  def link_identity!(user, uid)
    identity = Identity.find_or_initialize_by(provider: JUPYTERHUB_PROVIDER, uid: uid)
    return if identity.user_id == user.id

    identity.user = user
    identity.save!
  end

  def unique_user_name_for(uid, existing_user=nil)
    base = normalize_jupyterhub_username(uid)
    candidate = base
    suffix = 1

    while User.where.not(id: existing_user&.id).exists?(user_name: candidate)
      suffix += 1
      candidate = "#{base}-#{suffix}"
    end

    candidate
  end

  def normalize_jupyterhub_username(value)
    normalized = value.to_s.downcase.gsub(/[^a-z0-9\-_@\.]/, '-').gsub(/-+/, '-')
    normalized = normalized.sub(/\A[^a-z]+/, '')
    normalized = "u#{normalized}" if normalized.blank? || normalized !~ /\A[a-z]/
    normalized[0, 255]
  end

  def fallback_email_for(uid)
    domain = jupyterhub_fallback_email_domain
    return nil if domain.blank?

    local_part = normalize_jupyterhub_username(uid).tr('@', '-')
    "#{local_part}@#{domain}"
  end

  def extract_hub_uid(hub_user)
    uid = extract_claim(hub_user, jupyterhub_username_claims)
    raise 'JupyterHub user response did not include a username.' if uid.blank?

    uid
  end

  def extract_first_name(hub_user)
    first_name = extract_claim(hub_user, jupyterhub_first_name_claims)
    return first_name if first_name.present?

    display_name = extract_claim(hub_user, jupyterhub_display_name_claims)
    display_name.to_s.split.first.presence
  end

  def extract_last_name(hub_user)
    last_name = extract_claim(hub_user, jupyterhub_last_name_claims)
    return last_name if last_name.present?

    display_name = extract_claim(hub_user, jupyterhub_display_name_claims)
    parts = display_name.to_s.split
    return nil if parts.size < 2

    parts[1..].join(' ')
  end

  def extract_claim(payload, claim_paths)
    claim_paths.each do |path|
      value = dig_claim(payload, path)
      return value if value.present?
    end
    nil
  end

  def dig_claim(payload, path)
    current = payload
    path.to_s.split('.').each do |key|
      return nil unless current.is_a?(Hash)

      current = current[key] || current[key.to_sym]
    end
    current
  end

  def jupyterhub_oauth_enabled?
    jupyterhub_client_id.present? &&
      jupyterhub_client_secret.present? &&
      jupyterhub_base_url.present?
  end

  def jupyterhub_base_url
    ENV['JUPYTERHUB_BASE_URL'].presence ||
      GalleryConfig.dig(:jupyterhub_auth, :hub_url).presence
  end

  def jupyterhub_client_id
    ENV['JUPYTERHUB_CLIENT_ID'].presence ||
      GalleryConfig.dig(:jupyterhub_auth, :client_id).presence
  end

  def jupyterhub_client_secret
    ENV['JUPYTERHUB_CLIENT_SECRET'].presence ||
      GalleryConfig.dig(:jupyterhub_auth, :client_secret).presence
  end

  def jupyterhub_authorize_url
    build_jupyterhub_url(
      GalleryConfig.dig(:jupyterhub_auth, :authorize_path).presence || '/hub/api/oauth2/authorize'
    )
  end

  def jupyterhub_token_url
    build_jupyterhub_url(
      GalleryConfig.dig(:jupyterhub_auth, :token_path).presence || '/hub/api/oauth2/token'
    )
  end

  def jupyterhub_user_url
    build_jupyterhub_url(
      GalleryConfig.dig(:jupyterhub_auth, :user_path).presence || '/hub/api/user'
    )
  end

  def build_jupyterhub_url(path)
    "#{jupyterhub_base_url.to_s.sub(%r{/\z}, '')}#{path}"
  end

  def jupyterhub_scopes
    Array(GalleryConfig.dig(:jupyterhub_auth, :scopes)).map(&:to_s).reject(&:blank?)
  end

  def jupyterhub_username_claims
    config_claims(:username_claims, %w[name])
  end

  def jupyterhub_email_claims
    config_claims(:email_claims, %w[email])
  end

  def jupyterhub_first_name_claims
    config_claims(:first_name_claims, %w[first_name given_name])
  end

  def jupyterhub_last_name_claims
    config_claims(:last_name_claims, %w[last_name family_name])
  end

  def jupyterhub_display_name_claims
    config_claims(:display_name_claims, %w[display_name name])
  end

  def config_claims(key, defaults)
    Array(GalleryConfig.dig(:jupyterhub_auth, key)).presence || defaults
  end

  def jupyterhub_fallback_email_domain
    GalleryConfig.dig(:jupyterhub_auth, :fallback_email_domain).presence
  end

  def jupyterhub_link_existing_by_email?
    GalleryConfig.dig(:jupyterhub_auth, :link_existing_by_email) != false
  end

  def jupyterhub_link_existing_by_username?
    GalleryConfig.dig(:jupyterhub_auth, :link_existing_by_username) != false
  end
end
