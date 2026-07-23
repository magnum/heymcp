# frozen_string_literal: true

# Simple OAuth 2.1 authorization server for Claude Custom Connectors.
#
# Issues tokens after a username/password login form. Supports Dynamic Client
# Registration (DCR) so Claude can register itself without a pre-shared client id.
# The Ruby MCP SDK has no built-in authorization server, so the endpoints
# (metadata, /register, /authorize, /token, /revoke) are implemented here and
# mounted as routes in server.rb.

require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"
require "time"
require "uri"

class SimpleOAuthProvider
  SCOPE = "hey"
  ACCESS_TTL = 3600
  REFRESH_TTL = 30 * 24 * 3600
  AUTH_CODE_TTL = 300

  # Raised by flow methods; carries an HTTP status for the route handler.
  class OAuthError < StandardError
    attr_reader :status, :code

    def initialize(status, code, description)
      super(description)
      @status = status
      @code = code
    end

    def to_json_body
      JSON.generate(error: @code, error_description: message)
    end
  end

  attr_reader :public_url, :login_url

  def initialize(username:, password:, public_url:, static_bearer: nil)
    @username = username
    @password = password
    @public_url = public_url.sub(%r{/+\z}, "")
    @login_url = "#{@public_url}/login"
    @static_bearer = static_bearer.to_s
    @clients = {}
    @auth_codes = {}
    @tokens = {}
    @refresh_tokens = {}
    @state_mapping = {}
    @mutex = Mutex.new
  end

  # --- RFC 8414 / RFC 9728 metadata ---------------------------------------

  def authorization_server_metadata
    {
      issuer: @public_url,
      authorization_endpoint: "#{@public_url}/authorize",
      token_endpoint: "#{@public_url}/token",
      registration_endpoint: "#{@public_url}/register",
      revocation_endpoint: "#{@public_url}/revoke",
      scopes_supported: [SCOPE],
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["client_secret_post", "none"],
      revocation_endpoint_auth_methods_supported: ["client_secret_post", "none"],
      code_challenge_methods_supported: ["S256"],
    }
  end

  def protected_resource_metadata
    {
      resource: "#{@public_url}/mcp",
      authorization_servers: [@public_url],
      scopes_supported: [SCOPE],
      bearer_methods_supported: ["header"],
    }
  end

  # --- Dynamic Client Registration (RFC 7591) ------------------------------

  def register_client(metadata)
    redirect_uris = Array(metadata["redirect_uris"]).map(&:to_s).reject(&:empty?)
    if redirect_uris.empty?
      raise OAuthError.new(400, "invalid_client_metadata", "redirect_uris is required")
    end
    redirect_uris.each do |uri|
      parsed = URI.parse(uri) rescue nil
      unless parsed&.scheme && parsed.host
        raise OAuthError.new(400, "invalid_redirect_uri", "invalid redirect_uri: #{uri}")
      end
    end

    auth_method = metadata.fetch("token_endpoint_auth_method", "client_secret_post")
    client_id = SecureRandom.uuid
    client_secret = auth_method == "none" ? nil : SecureRandom.hex(32)

    client = {
      "client_id" => client_id,
      "client_secret" => client_secret,
      "client_id_issued_at" => Time.now.to_i,
      "client_secret_expires_at" => 0,
      "redirect_uris" => redirect_uris,
      "token_endpoint_auth_method" => auth_method,
      "grant_types" => Array(metadata["grant_types"] || ["authorization_code", "refresh_token"]),
      "response_types" => Array(metadata["response_types"] || ["code"]),
      "client_name" => metadata["client_name"],
      "scope" => metadata["scope"] || SCOPE,
    }.compact
    @mutex.synchronize { @clients[client_id] = client }
    client
  end

  def get_client(client_id)
    @mutex.synchronize { @clients[client_id] }
  end

  # --- Authorization flow ---------------------------------------------------

  # Validates /authorize params and returns the login URL to redirect to.
  def start_authorization(params)
    client = get_client(params["client_id"].to_s)
    raise OAuthError.new(400, "invalid_request", "unknown client_id") unless client

    unless params["response_type"] == "code"
      raise OAuthError.new(400, "unsupported_response_type", "only response_type=code is supported")
    end

    redirect_uri = params["redirect_uri"].to_s
    explicit = !redirect_uri.empty?
    if explicit
      unless client["redirect_uris"].include?(redirect_uri)
        raise OAuthError.new(400, "invalid_request", "redirect_uri not registered for this client")
      end
    else
      unless client["redirect_uris"].length == 1
        raise OAuthError.new(400, "invalid_request", "redirect_uri is required")
      end
      redirect_uri = client["redirect_uris"].first
    end

    code_challenge = params["code_challenge"].to_s
    raise OAuthError.new(400, "invalid_request", "code_challenge is required (PKCE S256)") if code_challenge.empty?
    method = params.fetch("code_challenge_method", "S256")
    unless method == "S256"
      raise OAuthError.new(400, "invalid_request", "only code_challenge_method=S256 is supported")
    end

    state = params["state"].to_s
    state = SecureRandom.hex(16) if state.empty?
    @mutex.synchronize do
      @state_mapping[state] = {
        redirect_uri: redirect_uri,
        redirect_uri_provided_explicitly: explicit,
        code_challenge: code_challenge,
        client_id: client["client_id"],
        resource: params["resource"],
      }
    end
    "#{@login_url}?state=#{URI.encode_www_form_component(state)}"
  end

  def valid_state?(state)
    @mutex.synchronize { @state_mapping.key?(state) }
  end

  def login_page(state)
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>hey-mcp login</title>
        <style>
          :root { color-scheme: light dark; }
          body { font-family: ui-sans-serif, system-ui, sans-serif; max-width: 420px;
                 margin: 4rem auto; padding: 0 1.25rem; line-height: 1.45; }
          h1 { font-size: 1.35rem; margin-bottom: 0.25rem; }
          p { color: #666; margin-top: 0; }
          label { display: block; font-size: 0.85rem; margin: 1rem 0 0.35rem; }
          input { width: 100%; box-sizing: border-box; padding: 0.65rem 0.75rem;
                  border: 1px solid #ccc; border-radius: 8px; font-size: 1rem; }
          button { margin-top: 1.25rem; width: 100%; padding: 0.75rem;
                   border: 0; border-radius: 8px; background: #111; color: #fff;
                   font-size: 1rem; cursor: pointer; }
          @media (prefers-color-scheme: dark) {
            p { color: #aaa; }
            input { border-color: #444; background: #1a1a1a; color: #eee; }
            button { background: #eee; color: #111; }
          }
        </style>
      </head>
      <body>
        <h1>hey-mcp</h1>
        <p>Sign in to authorize Claude to access your HEY MCP server.</p>
        <form method="post" action="#{@public_url}/login/callback">
          <input type="hidden" name="state" value="#{escape_html(state)}"/>
          <label for="username">Username</label>
          <input id="username" name="username" autocomplete="username" required/>
          <label for="password">Password</label>
          <input id="password" name="password" type="password" autocomplete="current-password" required/>
          <button type="submit">Authorize</button>
        </form>
      </body>
      </html>
    HTML
  end

  # Verifies credentials, mints an auth code, returns the redirect URL.
  def handle_login(username:, password:, state:)
    if username.to_s.empty? || password.to_s.empty? || state.to_s.empty?
      raise OAuthError.new(400, "invalid_request", "Missing username, password, or state")
    end
    unless secure_equals(username, @username) && secure_equals(password, @password)
      raise OAuthError.new(401, "access_denied", "Invalid credentials")
    end

    state_data = @mutex.synchronize { @state_mapping.delete(state) }
    raise OAuthError.new(400, "invalid_request", "Invalid state parameter") unless state_data

    code = "mcp_#{SecureRandom.hex(16)}"
    @mutex.synchronize do
      @auth_codes[code] = {
        code: code,
        client_id: state_data[:client_id],
        redirect_uri: state_data[:redirect_uri],
        expires_at: Time.now.to_i + AUTH_CODE_TTL,
        scopes: [SCOPE],
        code_challenge: state_data[:code_challenge],
        resource: state_data[:resource],
        subject: username,
      }
    end
    append_query(state_data[:redirect_uri], code: code, state: state)
  end

  # --- Token endpoint -------------------------------------------------------

  def token_request(params)
    case params["grant_type"]
    when "authorization_code" then exchange_authorization_code(params)
    when "refresh_token" then exchange_refresh_token(params)
    else
      raise OAuthError.new(400, "unsupported_grant_type", "use authorization_code or refresh_token")
    end
  end

  def revoke_token(token)
    @mutex.synchronize do
      @tokens.delete(token)
      @refresh_tokens.delete(token)
    end
  end

  # Returns an access-token hash (or nil). Accepts MCP_AUTH_TOKEN as a
  # permanent API key alongside OAuth-issued tokens.
  def load_access_token(token)
    return nil if token.to_s.empty?

    if !@static_bearer.empty? && secure_equals(token, @static_bearer)
      return { token: token, client_id: "static-bearer", scopes: [SCOPE], expires_at: nil, subject: "static-bearer" }
    end

    @mutex.synchronize do
      access = @tokens[token]
      return nil unless access
      if access[:expires_at] && access[:expires_at] < Time.now.to_i
        @tokens.delete(token)
        return nil
      end
      access
    end
  end

  private

  def exchange_authorization_code(params)
    client = authenticate_client(params)
    code_data = @mutex.synchronize { @auth_codes[params["code"].to_s] }
    raise OAuthError.new(400, "invalid_grant", "invalid authorization code") unless code_data
    raise OAuthError.new(400, "invalid_grant", "code was issued to another client") if code_data[:client_id] != client["client_id"]

    if code_data[:expires_at] < Time.now.to_i
      @mutex.synchronize { @auth_codes.delete(code_data[:code]) }
      raise OAuthError.new(400, "invalid_grant", "authorization code expired")
    end

    redirect_uri = params["redirect_uri"].to_s
    if !redirect_uri.empty? && redirect_uri != code_data[:redirect_uri]
      raise OAuthError.new(400, "invalid_grant", "redirect_uri mismatch")
    end

    verifier = params["code_verifier"].to_s
    raise OAuthError.new(400, "invalid_grant", "code_verifier is required") if verifier.empty?
    expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    unless secure_equals(expected, code_data[:code_challenge])
      raise OAuthError.new(400, "invalid_grant", "PKCE verification failed")
    end

    @mutex.synchronize { @auth_codes.delete(code_data[:code]) }
    issue_tokens(client["client_id"], code_data[:scopes], code_data[:subject], resource: code_data[:resource])
  end

  def exchange_refresh_token(params)
    client = authenticate_client(params)
    refresh = @mutex.synchronize { @refresh_tokens[params["refresh_token"].to_s] }
    raise OAuthError.new(400, "invalid_grant", "invalid refresh token") unless refresh
    raise OAuthError.new(400, "invalid_grant", "refresh token was issued to another client") if refresh[:client_id] != client["client_id"]

    if refresh[:expires_at] && refresh[:expires_at] < Time.now.to_i
      @mutex.synchronize { @refresh_tokens.delete(refresh[:token]) }
      raise OAuthError.new(400, "invalid_grant", "refresh token expired")
    end

    requested = params["scope"].to_s.split
    scopes = requested.empty? ? refresh[:scopes] : requested
    unless (scopes - refresh[:scopes]).empty?
      raise OAuthError.new(400, "invalid_scope", "cannot broaden scopes on refresh")
    end

    # Rotate: the old refresh token is single-use.
    @mutex.synchronize { @refresh_tokens.delete(refresh[:token]) }
    issue_tokens(client["client_id"], scopes, refresh[:subject])
  end

  def issue_tokens(client_id, scopes, subject, resource: nil)
    access = "mcp_#{SecureRandom.hex(32)}"
    refresh = "mcp_rt_#{SecureRandom.hex(32)}"
    now = Time.now.to_i

    @mutex.synchronize do
      @tokens[access] = {
        token: access, client_id: client_id, scopes: scopes,
        expires_at: now + ACCESS_TTL, resource: resource, subject: subject,
      }
      @refresh_tokens[refresh] = {
        token: refresh, client_id: client_id, scopes: scopes,
        expires_at: now + REFRESH_TTL, subject: subject,
      }
    end

    {
      access_token: access,
      refresh_token: refresh,
      token_type: "Bearer",
      expires_in: ACCESS_TTL,
      scope: scopes.join(" "),
    }
  end

  def authenticate_client(params)
    client = get_client(params["client_id"].to_s)
    raise OAuthError.new(401, "invalid_client", "unknown client_id") unless client

    if client["token_endpoint_auth_method"] != "none"
      secret = params["client_secret"].to_s
      unless !secret.empty? && secure_equals(secret, client["client_secret"].to_s)
        raise OAuthError.new(401, "invalid_client", "invalid client_secret")
      end
    end
    client
  end

  def secure_equals(a, b)
    OpenSSL.fixed_length_secure_compare(Digest::SHA256.digest(a.to_s), Digest::SHA256.digest(b.to_s))
  end

  def append_query(url, extra)
    uri = URI.parse(url)
    query = URI.decode_www_form(uri.query || "")
    extra.each { |k, v| query << [k.to_s, v] }
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  def escape_html(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end
end
