require 'test_helper'

class JupyterhubOauthControllerTest < ActionController::TestCase
  setup do
    @routes = Rails.application.routes
    @request.env['devise.mapping'] = Devise.mappings[:user]
    @original_host = GalleryConfig.jupyterhub_auth.hub_url
    @original_client_id = GalleryConfig.jupyterhub_auth.client_id
    @original_client_secret = GalleryConfig.jupyterhub_auth.client_secret
    @original_fallback_email_domain = GalleryConfig.jupyterhub_auth.fallback_email_domain
    @original_require_admin_approval = GalleryConfig.registration.require_admin_approval
    GalleryConfig.jupyterhub_auth.hub_url = 'https://jupyterhub.example.edu'
    GalleryConfig.jupyterhub_auth.client_id = 'client-id'
    GalleryConfig.jupyterhub_auth.client_secret = 'client-secret'
    GalleryConfig.jupyterhub_auth.fallback_email_domain = 'example.edu'
    GalleryConfig.registration.require_admin_approval = false
  end

  teardown do
    GalleryConfig.jupyterhub_auth.hub_url = @original_host
    GalleryConfig.jupyterhub_auth.client_id = @original_client_id
    GalleryConfig.jupyterhub_auth.client_secret = @original_client_secret
    GalleryConfig.jupyterhub_auth.fallback_email_domain = @original_fallback_email_domain
    GalleryConfig.registration.require_admin_approval = @original_require_admin_approval
  end

  test 'start redirects to jupyterhub authorize url' do
    get :start, params: { return_to: '/notebooks' }

    assert_response :redirect
    assert_match 'https://jupyterhub.example.edu/hub/api/oauth2/authorize', @response.location
    assert_equal '/notebooks', session[:jupyterhub_oauth_return_to]
    assert session[:jupyterhub_oauth_state].present?
  end

  test 'callback signs in existing linked user' do
    session[:jupyterhub_oauth_state] = 'expected-state'
    session[:jupyterhub_oauth_return_to] = '/notebooks'

    @controller.stub(:exchange_code_for_token, { 'access_token' => 'token-123' }) do
      @controller.stub(:fetch_hub_user, { 'name' => 'existing-user', 'email' => 'one@example.com' }) do
        get :callback, params: { code: 'oauth-code', state: 'expected-state' }
      end
    end

    assert_redirected_to '/notebooks'
    assert_equal users(:one).id, @controller.current_user.id
  end

  test 'callback uses email-shaped hub username when email is missing' do
    session[:jupyterhub_oauth_state] = 'expected-state'

    assert_difference('User.count', 1) do
      assert_difference('Identity.count', 1) do
        @controller.stub(:exchange_code_for_token, { 'access_token' => 'token-123' }) do
          @controller.stub(:fetch_hub_user, { 'name' => 'user@example.edu', 'first_name' => 'Test', 'last_name' => 'User' }) do
            get :callback, params: { code: 'oauth-code', state: 'expected-state' }
          end
        end
      end
    end

    user = User.order(:id).last
    assert_equal 'user@example.edu', user.email
    assert_equal 'user@example.edu', Identity.order(:id).last.uid
  end

  test 'callback creates a local user when no linked account exists' do
    session[:jupyterhub_oauth_state] = 'expected-state'

    assert_difference('User.count', 1) do
      assert_difference('Identity.count', 1) do
        @controller.stub(:exchange_code_for_token, { 'access_token' => 'token-123' }) do
          @controller.stub(:fetch_hub_user, { 'name' => 'hub-user', 'email' => 'hub-user@example.edu', 'first_name' => 'Hub', 'last_name' => 'User' }) do
            get :callback, params: { code: 'oauth-code', state: 'expected-state' }
          end
        end
      end
    end

    user = User.order(:id).last
    identity = Identity.order(:id).last
    assert_equal 'hub-user@example.edu', user.email
    assert_equal 'hub-user', user.user_name
    assert_equal user.id, identity.user_id
    assert_equal 'jupyterhub', identity.provider
  end

  test 'callback links an existing user by email' do
    session[:jupyterhub_oauth_state] = 'expected-state'

    assert_no_difference('User.count') do
      assert_difference('Identity.count', 1) do
        @controller.stub(:exchange_code_for_token, { 'access_token' => 'token-123' }) do
          @controller.stub(:fetch_hub_user, { 'name' => 'new-hub-name', 'email' => 'two@example.com' }) do
            get :callback, params: { code: 'oauth-code', state: 'expected-state' }
          end
        end
      end
    end

    assert_equal users(:two).id, Identity.order(:id).last.user_id
  end
end
