# frozen_string_literal: true

# MCP server wrapping the HEY CLI (https://github.com/basecamp/hey-cli).
#
# Transport is selected via MCP_TRANSPORT:
#   - "http"  (default) streamable HTTP, for use across the LAN
#   - "stdio"           for local testing with `docker run -i`
#
# Auth modes (HTTP):
#   - OAuth (Claude Custom Connector): set MCP_PUBLIC_URL + password
#   - Bearer token (mcp-remote --header): set MCP_AUTH_TOKEN without MCP_PUBLIC_URL,
#     or set MCP_AUTH_MODE=bearer
#
# Write tools are gated:
#   - HEY_ALLOW_SEND=true   → compose, reply
#   - HEY_ALLOW_WRITE=true  → seen/unseen, todos, habits, timetrack start/stop, journal write

require "json"
require "mcp"

require_relative "hey_client"
require_relative "oauth_provider"

TOKEN = ENV.fetch("MCP_AUTH_TOKEN", "")
TRANSPORT = ENV.fetch("MCP_TRANSPORT", "http").downcase
ALLOW_SEND = ENV.fetch("HEY_ALLOW_SEND", "true").downcase == "true"
ALLOW_WRITE = ENV.fetch("HEY_ALLOW_WRITE", "true").downcase == "true"
HOST = ENV.fetch("MCP_HOST", "0.0.0.0")
PORT = ENV.fetch("MCP_PORT", "8765").to_i
PUBLIC_URL = ENV.fetch("MCP_PUBLIC_URL", "").sub(%r{/+\z}, "")
AUTH_MODE = ENV.fetch("MCP_AUTH_MODE", "").downcase # oauth | bearer | auto
OAUTH_USERNAME = ENV.fetch("MCP_OAUTH_USERNAME", "admin")
OAUTH_PASSWORD = ENV.fetch("MCP_OAUTH_PASSWORD", "").empty? ? TOKEN : ENV["MCP_OAUTH_PASSWORD"]

# DNS rebinding protection: Host must be allowlisted when behind Cloudflare/proxy.
raw_hosts = ENV.fetch("MCP_ALLOWED_HOSTS", "localhost,127.0.0.1")
ALLOWED_HOSTS = raw_hosts.split(",").map(&:strip).reject(&:empty?).flat_map do |h|
  h.delete_prefix("[").delete_suffix("]").include?(":") ? [h] : [h, "#{h}:*"]
end.freeze

raw_origins = ENV.fetch("MCP_ALLOWED_ORIGINS", "")
allowed_origins = raw_origins.split(",").map(&:strip).reject(&:empty?)
if allowed_origins.empty?
  raw_hosts.split(",").map(&:strip).reject(&:empty?).each do |h|
    base = h.start_with?("[") ? h : h.split(":").first
    allowed_origins.push("https://#{base}", "http://#{base}")
  end
end
allowed_origins << PUBLIC_URL unless PUBLIC_URL.empty?
ALLOWED_ORIGINS = allowed_origins.freeze

def oauth_enabled?
  return false if AUTH_MODE == "bearer"
  return true if AUTH_MODE == "oauth"

  # auto: OAuth when public URL + password are configured
  !PUBLIC_URL.empty? && !OAUTH_PASSWORD.empty?
end

OAUTH_PROVIDER =
  if oauth_enabled?
    abort("MCP_PUBLIC_URL is required for OAuth (e.g. https://heymcp.example.com)") if PUBLIC_URL.empty?
    abort("Set MCP_OAUTH_PASSWORD or MCP_AUTH_TOKEN for OAuth login") if OAUTH_PASSWORD.empty?

    SimpleOAuthProvider.new(
      username: OAUTH_USERNAME,
      password: OAUTH_PASSWORD,
      public_url: PUBLIC_URL,
      static_bearer: TOKEN.empty? ? nil : TOKEN,
    )
  end

# --- Tool helpers ------------------------------------------------------------

def tool_text(text)
  MCP::Tool::Response.new([{ type: "text", text: text }])
end

def call_hey(args)
  tool_text(HeyClient.run(args))
rescue HeyClient::HeyError => e
  tool_text("ERROR: #{e.message}")
end

def require_value(value, name)
  return nil unless value.to_s.strip.empty?

  tool_text("ERROR: #{name} is required")
end

def gate(enabled, flag)
  return nil if enabled

  tool_text("ERROR: disabled. Set #{flag}=true in .env and restart.")
end

# Build a readable plain-text body. Prefer paragraphs (joined with blank lines).
def email_body(message, paragraphs)
  parts = Array(paragraphs).map { |p| p.to_s.strip }.reject(&:empty?)
  return parts.join("\n\n") unless parts.empty?

  text = message.to_s.strip
  return nil if text.empty?

  # Soft fix: if the model sent one huge line, break after sentence ends
  # followed by a capital letter — last resort only.
  if !text.include?("\n") && text.length > 280
    text = text.gsub(/([.!?])\s+(?=[A-ZÀ-ÖØ-Þ0-9])/, "\\1\n\n")
  end
  text
end

def skill_text
  [
    File.join(__dir__, "skills", "hey", "SKILL.md"),
    "/app/skills/hey/SKILL.md",
  ].each do |candidate|
    return File.read(candidate) if File.file?(candidate)
  end
  "SKILL.md not found in image. See https://github.com/basecamp/hey-cli/blob/main/skills/hey/SKILL.md"
end

def string_prop(desc) = { type: "string", description: desc }
def int_prop(desc) = { type: "integer", description: desc }
def bool_prop(desc) = { type: "boolean", description: desc }
def array_prop(desc) = { type: "array", items: { type: "string" }, description: desc }

LIMIT_PROPS = {
  limit: int_prop("max items"),
  fetch_all: bool_prop("pass --all (ignore limit)"),
}.freeze

def clean(value)
  v = value.to_s.strip
  v.empty? ? nil : v
end

# --- MCP server ---------------------------------------------------------------

MCP_SERVER = MCP::Server.new(
  name: "hey",
  version: "1.0.0",
  instructions:
    "HEY email MCP. Before complex workflows call hey_skill. " \
    "For hey_compose / hey_reply ALWAYS pass `paragraphs` as an array of short " \
    "paragraphs (greeting, body blocks, numbered options, closing, signature). " \
    "Never send the whole email as one unbroken line in `message`.",
  resources: [
    MCP::Resource.new(
      uri: "hey://skill",
      name: "hey_skill",
      description: "Official HEY CLI agent skill (workflows, ID rules, command reference).",
      mime_type: "text/markdown",
    ),
  ],
)

MCP_SERVER.resources_read_handler do |params|
  [{ uri: params[:uri], mimeType: "text/markdown", text: skill_text }]
end

# --- Skill (vendored from hey-cli) --------------------------------------------

MCP_SERVER.define_tool(
  name: "hey_skill",
  description: "Return the HEY CLI agent skill: decision trees, ID rules (topic_id vs posting id), " \
               "and command reference. Read this before complex HEY workflows.",
) do |**|
  tool_text(skill_text)
end

# --- Auth & diagnostics --------------------------------------------------------

MCP_SERVER.define_tool(
  name: "hey_auth_status",
  description: "Check whether the hey CLI is authenticated with HEY (`hey auth status --json`).",
) do |**|
  call_hey(HeyClient.cmd_auth_status)
end

MCP_SERVER.define_tool(
  name: "hey_auth_token",
  description: "Print the HEY access token (`hey auth token --quiet`). Sensitive — only when needed.",
) do |**|
  call_hey(HeyClient.cmd_auth_token)
end

MCP_SERVER.define_tool(
  name: "hey_doctor",
  description: "Check hey CLI system health and configuration (`hey doctor --json`).",
) do |**|
  call_hey(HeyClient.cmd_doctor)
end

MCP_SERVER.define_tool(
  name: "hey_config_show",
  description: "Show hey CLI configuration and sources (`hey config show --json`).",
) do |**|
  call_hey(HeyClient.cmd_config_show)
end

# --- Email ----------------------------------------------------------------------

MCP_SERVER.define_tool(
  name: "hey_boxes",
  description: "List HEY mailboxes (`hey boxes --json`). " \
               "Names: imbox, feedbox, trailbox, asidebox, laterbox, bubblebox.",
  input_schema: { properties: LIMIT_PROPS.dup, required: [] },
) do |limit: nil, fetch_all: false, **|
  call_hey(HeyClient.cmd_boxes(limit, fetch_all: fetch_all))
end

MCP_SERVER.define_tool(
  name: "hey_box",
  description: "List postings in a mailbox (`hey box <name|id> --json`). Each posting has `id` " \
               "(posting ID for seen/unseen) and `topic_id` (for threads/reply).",
  input_schema: {
    properties: {
      name_or_id: string_prop("mailbox name or numeric ID (default imbox)"),
      limit: int_prop("max postings (default 20)"),
      fetch_all: bool_prop("pass --all"),
    },
    required: [],
  },
) do |name_or_id: "imbox", limit: 20, fetch_all: false, **|
  require_value(name_or_id, "name_or_id") ||
    call_hey(HeyClient.cmd_box(name_or_id.strip, limit, fetch_all: fetch_all))
end

MCP_SERVER.define_tool(
  name: "hey_threads",
  description: "Read a full email thread (`hey threads <topic_id> --json`). " \
               "Use topic_id from hey_box, not posting id.",
  input_schema: {
    properties: {
      topic_id: string_prop("topic ID"),
      html: bool_prop("also request --html content when supported"),
    },
    required: ["topic_id"],
  },
) do |topic_id:, html: false, **|
  require_value(topic_id, "topic_id") ||
    call_hey(HeyClient.cmd_threads(topic_id.strip, html: html))
end

MCP_SERVER.define_tool(
  name: "hey_drafts",
  description: "List drafts (`hey drafts --json`).",
  input_schema: { properties: LIMIT_PROPS.dup, required: [] },
) do |limit: nil, fetch_all: false, **|
  call_hey(HeyClient.cmd_drafts(limit, fetch_all: fetch_all))
end

MCP_SERVER.define_tool(
  name: "hey_compose",
  description: "Compose/send email. Confirm with the user first. " \
               "Body formatting (MANDATORY): pass `paragraphs` — one string per paragraph / " \
               "list item / signature. They are joined with blank lines. Do NOT put the " \
               "entire email in a single run-on `message` string.",
  input_schema: {
    properties: {
      subject: string_prop("required subject"),
      paragraphs: array_prop("preferred body as list of paragraphs (joined with \\n\\n)"),
      message: string_prop("fallback single body only for one short sentence; prefer paragraphs"),
      to: string_prop("recipient(s)"),
      cc: string_prop("CC recipient(s)"),
      bcc: string_prop("BCC recipient(s)"),
      thread_id: string_prop("post into existing thread instead of/in addition to to"),
    },
    required: ["subject"],
  },
) do |subject:, paragraphs: nil, message: nil, to: nil, cc: nil, bcc: nil, thread_id: nil, **|
  body = email_body(message, paragraphs)
  gate(ALLOW_SEND, "HEY_ALLOW_SEND") ||
    require_value(subject, "subject") ||
    (body.nil? ? tool_text("ERROR: provide paragraphs (preferred) or message") : nil) ||
    (clean(to).nil? && clean(thread_id).nil? ? tool_text("ERROR: provide to and/or thread_id") : nil) ||
    call_hey(
      HeyClient.cmd_compose(
        subject: subject.strip,
        message: body,
        to: clean(to),
        cc: clean(cc),
        bcc: clean(bcc),
        thread_id: clean(thread_id),
      ),
    )
end

MCP_SERVER.define_tool(
  name: "hey_reply",
  description: "Reply to a thread. Confirm with the user first. " \
               "Body formatting (MANDATORY): pass `paragraphs` as an array of short paragraphs " \
               "(greeting, points, closing, signature). Joined with blank lines. Avoid one " \
               "long unbroken `message`.",
  input_schema: {
    properties: {
      topic_id: string_prop("topic ID from hey_box"),
      paragraphs: array_prop("preferred body as list of paragraphs"),
      message: string_prop("fallback for a one-line reply only"),
    },
    required: ["topic_id"],
  },
) do |topic_id:, paragraphs: nil, message: nil, **|
  body = email_body(message, paragraphs)
  gate(ALLOW_SEND, "HEY_ALLOW_SEND") ||
    require_value(topic_id, "topic_id") ||
    (body.nil? ? tool_text("ERROR: provide paragraphs (preferred) or message") : nil) ||
    call_hey(HeyClient.cmd_reply(topic_id.strip, body))
end

MCP_SERVER.define_tool(
  name: "hey_seen",
  description: "Mark posting(s) as seen (`hey seen <id>...`). Use posting id from hey_box, not topic_id.",
  input_schema: {
    properties: { posting_ids: array_prop("one or more posting IDs") },
    required: ["posting_ids"],
  },
) do |posting_ids:, **|
  ids = Array(posting_ids).map { |p| p.to_s.strip }.reject(&:empty?)
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    (ids.empty? ? tool_text("ERROR: posting_ids is required") : nil) ||
    call_hey(HeyClient.cmd_seen(ids))
end

MCP_SERVER.define_tool(
  name: "hey_unseen",
  description: "Mark posting(s) as unseen (`hey unseen <id>...`). Use posting id from hey_box.",
  input_schema: {
    properties: { posting_ids: array_prop("one or more posting IDs") },
    required: ["posting_ids"],
  },
) do |posting_ids:, **|
  ids = Array(posting_ids).map { |p| p.to_s.strip }.reject(&:empty?)
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    (ids.empty? ? tool_text("ERROR: posting_ids is required") : nil) ||
    call_hey(HeyClient.cmd_unseen(ids))
end

# --- Calendar & todos -------------------------------------------------------------

MCP_SERVER.define_tool(
  name: "hey_calendars",
  description: "List calendars (`hey calendars --json`) → [{id, name, kind}, ...].",
) do |**|
  call_hey(HeyClient.cmd_calendars)
end

MCP_SERVER.define_tool(
  name: "hey_recordings",
  description: "List calendar recordings (`hey recordings <id> --json`). " \
               "Grouped by Calendar::Event / Habit / Todo.",
  input_schema: {
    properties: {
      calendar_id: string_prop("from hey_calendars"),
      starts_on: string_prop("YYYY-MM-DD (default today)"),
      ends_on: string_prop("YYYY-MM-DD"),
      limit: int_prop("max per type"),
      fetch_all: bool_prop("pass --all"),
    },
    required: ["calendar_id"],
  },
) do |calendar_id:, starts_on: nil, ends_on: nil, limit: nil, fetch_all: false, **|
  require_value(calendar_id, "calendar_id") ||
    call_hey(
      HeyClient.cmd_recordings(
        calendar_id.strip,
        starts_on: clean(starts_on),
        ends_on: clean(ends_on),
        limit: limit,
        fetch_all: fetch_all,
      ),
    )
end

MCP_SERVER.define_tool(
  name: "hey_todo_list",
  description: "List todos (`hey todo list --json`).",
  input_schema: { properties: LIMIT_PROPS.dup, required: [] },
) do |limit: nil, fetch_all: false, **|
  call_hey(HeyClient.cmd_todo_list(limit, fetch_all: fetch_all))
end

MCP_SERVER.define_tool(
  name: "hey_todo_add",
  description: "Create a todo (`hey todo add \"...\"`).",
  input_schema: {
    properties: {
      title: string_prop("todo title"),
      date: string_prop("optional due date YYYY-MM-DD"),
    },
    required: ["title"],
  },
) do |title:, date: nil, **|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    require_value(title, "title") ||
    call_hey(HeyClient.cmd_todo_add(title.strip, clean(date)))
end

MCP_SERVER.define_tool(
  name: "hey_todo_complete",
  description: "Mark todo complete (`hey todo complete <id>`).",
  input_schema: { properties: { todo_id: string_prop("todo ID") }, required: ["todo_id"] },
) do |todo_id:, **|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    require_value(todo_id, "todo_id") ||
    call_hey(HeyClient.cmd_todo_complete(todo_id.strip))
end

MCP_SERVER.define_tool(
  name: "hey_todo_uncomplete",
  description: "Mark todo incomplete (`hey todo uncomplete <id>`).",
  input_schema: { properties: { todo_id: string_prop("todo ID") }, required: ["todo_id"] },
) do |todo_id:, **|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    require_value(todo_id, "todo_id") ||
    call_hey(HeyClient.cmd_todo_uncomplete(todo_id.strip))
end

MCP_SERVER.define_tool(
  name: "hey_todo_delete",
  description: "Delete a todo (`hey todo delete <id>`).",
  input_schema: { properties: { todo_id: string_prop("todo ID") }, required: ["todo_id"] },
) do |todo_id:, **|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    require_value(todo_id, "todo_id") ||
    call_hey(HeyClient.cmd_todo_delete(todo_id.strip))
end

MCP_SERVER.define_tool(
  name: "hey_habit_complete",
  description: "Complete a habit (`hey habit complete <id>`). IDs from hey_recordings Calendar::Habit.",
  input_schema: {
    properties: {
      habit_id: string_prop("habit ID"),
      date: string_prop("optional YYYY-MM-DD (default today)"),
    },
    required: ["habit_id"],
  },
) do |habit_id:, date: nil, **|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    require_value(habit_id, "habit_id") ||
    call_hey(HeyClient.cmd_habit_complete(habit_id.strip, clean(date)))
end

MCP_SERVER.define_tool(
  name: "hey_habit_uncomplete",
  description: "Uncomplete a habit (`hey habit uncomplete <id>`).",
  input_schema: {
    properties: {
      habit_id: string_prop("habit ID"),
      date: string_prop("optional YYYY-MM-DD"),
    },
    required: ["habit_id"],
  },
) do |habit_id:, date: nil, **|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    require_value(habit_id, "habit_id") ||
    call_hey(HeyClient.cmd_habit_uncomplete(habit_id.strip, clean(date)))
end

MCP_SERVER.define_tool(
  name: "hey_timetrack_start",
  description: "Start time tracking (`hey timetrack start`).",
) do |**|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") || call_hey(HeyClient.cmd_timetrack_start)
end

MCP_SERVER.define_tool(
  name: "hey_timetrack_stop",
  description: "Stop time tracking (`hey timetrack stop`).",
) do |**|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") || call_hey(HeyClient.cmd_timetrack_stop)
end

MCP_SERVER.define_tool(
  name: "hey_timetrack_current",
  description: "Show current timer (`hey timetrack current --json`).",
) do |**|
  call_hey(HeyClient.cmd_timetrack_current)
end

MCP_SERVER.define_tool(
  name: "hey_timetrack_list",
  description: "List time tracks (`hey timetrack list --json`).",
  input_schema: { properties: LIMIT_PROPS.dup, required: [] },
) do |limit: nil, fetch_all: false, **|
  call_hey(HeyClient.cmd_timetrack_list(limit, fetch_all: fetch_all))
end

MCP_SERVER.define_tool(
  name: "hey_journal_list",
  description: "List journal entries (`hey journal list --json`).",
  input_schema: { properties: LIMIT_PROPS.dup, required: [] },
) do |limit: nil, fetch_all: false, **|
  call_hey(HeyClient.cmd_journal_list(limit, fetch_all: fetch_all))
end

MCP_SERVER.define_tool(
  name: "hey_journal_read",
  description: "Read a journal entry (`hey journal read [date] --json`). Default: today.",
  input_schema: {
    properties: {
      date: string_prop("optional YYYY-MM-DD"),
      html: bool_prop("pass --html when supported"),
    },
    required: [],
  },
) do |date: nil, html: false, **|
  call_hey(HeyClient.cmd_journal_read(clean(date), html: html))
end

MCP_SERVER.define_tool(
  name: "hey_journal_write",
  description: "Write a journal entry (`hey journal write -c \"...\"`). Default date: today.",
  input_schema: {
    properties: {
      content: string_prop("journal text (required; no $EDITOR in MCP)"),
      date: string_prop("optional YYYY-MM-DD"),
    },
    required: ["content"],
  },
) do |content:, date: nil, **|
  gate(ALLOW_WRITE, "HEY_ALLOW_WRITE") ||
    require_value(content, "content") ||
    call_hey(HeyClient.cmd_journal_write(content, clean(date)))
end

# --- HTTP app (Sinatra) --------------------------------------------------------

def build_http_app
  require "sinatra/base"

  Class.new(Sinatra::Base) do
    set :environment, :production
    set :host_authorization, permitted_hosts: [] # we do our own Host check on /mcp
    set :server, :puma
    set :bind, HOST
    set :port, PORT
    set :logging, true
    set :show_exceptions, false

    helpers do
      def json_response(payload, status_code = 200)
        status status_code
        content_type :json
        JSON.generate(payload)
      end

      def bearer_token
        header = request.env["HTTP_AUTHORIZATION"].to_s
        header.start_with?("Bearer ") ? header.delete_prefix("Bearer ") : nil
      end

      def static_bearer_valid?(token)
        return false if TOKEN.empty? || token.nil?
        return false unless token.bytesize == TOKEN.bytesize

        OpenSSL.fixed_length_secure_compare(token, TOKEN)
      end

      def authorized?
        token = bearer_token
        if OAUTH_PROVIDER
          !OAUTH_PROVIDER.load_access_token(token.to_s).nil?
        else
          static_bearer_valid?(token)
        end
      end

      def unauthorized!
        if OAUTH_PROVIDER
          headers["WWW-Authenticate"] =
            %(Bearer error="invalid_token", resource_metadata="#{PUBLIC_URL}/.well-known/oauth-protected-resource/mcp")
          halt 401, { "Content-Type" => "application/json" },
            JSON.generate(error: "invalid_token", error_description: "Authentication required")
        else
          halt 401, { "Content-Type" => "application/json" }, JSON.generate(error: "unauthorized")
        end
      end

      # DNS rebinding protection (mirrors the Python SDK's TransportSecuritySettings).
      def check_transport_security!
        host = request.env["HTTP_HOST"].to_s
        allowed = ALLOWED_HOSTS.any? do |pattern|
          if pattern.end_with?(":*")
            host.split(":").first == pattern.delete_suffix(":*")
          else
            host == pattern
          end
        end
        halt 421, { "Content-Type" => "text/plain" }, "Invalid Host header" unless allowed

        origin = request.env["HTTP_ORIGIN"].to_s
        if !origin.empty? && !ALLOWED_ORIGINS.include?(origin)
          halt 403, { "Content-Type" => "text/plain" }, "Invalid Origin header"
        end
      end

      def oauth_error(err)
        status err.status
        content_type :json
        err.to_json_body
      end
    end

    get "/healthz" do
      json_response(
        status: "ok",
        send_enabled: ALLOW_SEND,
        write_enabled: ALLOW_WRITE,
        auth: OAUTH_PROVIDER && !TOKEN.empty? ? "oauth+bearer" : (OAUTH_PROVIDER ? "oauth" : "bearer"),
        public_url: PUBLIC_URL.empty? ? nil : PUBLIC_URL,
      )
    end

    post "/mcp" do
      check_transport_security!
      unauthorized! unless authorized?

      body = request.body.read
      halt 400, { "Content-Type" => "application/json" },
        JSON.generate(error: "empty request body") if body.to_s.empty?

      result = MCP_SERVER.handle_json(body)
      if result.nil?
        status 202 # notification: no JSON-RPC response
        ""
      else
        content_type :json
        result
      end
    end

    # Stateless server: no SSE stream, no session to delete.
    get("/mcp") { halt 405, { "Allow" => "POST" }, "" }
    delete("/mcp") { halt 405, { "Allow" => "POST" }, "" }

    if OAUTH_PROVIDER
      # RFC 8414 authorization server metadata (base and path-suffixed probes).
      ["/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/mcp"].each do |path|
        get path do
          headers["Access-Control-Allow-Origin"] = "*"
          json_response(OAUTH_PROVIDER.authorization_server_metadata)
        end
      end

      # RFC 9728 protected resource metadata.
      ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"].each do |path|
        get path do
          headers["Access-Control-Allow-Origin"] = "*"
          json_response(OAUTH_PROVIDER.protected_resource_metadata)
        end
      end

      post "/register" do
        metadata = JSON.parse(request.body.read) rescue nil
        halt 400, { "Content-Type" => "application/json" },
          JSON.generate(error: "invalid_client_metadata", error_description: "body must be JSON") unless metadata.is_a?(Hash)
        json_response(OAUTH_PROVIDER.register_client(metadata), 201)
      rescue SimpleOAuthProvider::OAuthError => e
        oauth_error(e)
      end

      get "/authorize" do
        redirect OAUTH_PROVIDER.start_authorization(params), 302
      rescue SimpleOAuthProvider::OAuthError => e
        oauth_error(e)
      end

      get "/login" do
        state = params["state"].to_s
        if state.empty? || !OAUTH_PROVIDER.valid_state?(state)
          halt 400, { "Content-Type" => "application/json" },
            JSON.generate(error: "invalid_request", error_description: "Missing or invalid state")
        end
        content_type :html
        OAUTH_PROVIDER.login_page(state)
      end

      post "/login/callback" do
        redirect OAUTH_PROVIDER.handle_login(
          username: params["username"].to_s,
          password: params["password"].to_s,
          state: params["state"].to_s,
        ), 302
      rescue SimpleOAuthProvider::OAuthError => e
        oauth_error(e)
      end

      post "/token" do
        json_response(OAUTH_PROVIDER.token_request(params))
      rescue SimpleOAuthProvider::OAuthError => e
        oauth_error(e)
      end

      post "/revoke" do
        OAUTH_PROVIDER.revoke_token(params["token"].to_s)
        json_response({})
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  if TRANSPORT == "stdio"
    MCP::Server::Transports::StdioTransport.new(MCP_SERVER).open
  else
    if OAUTH_PROVIDER.nil? && TOKEN.empty?
      abort(
        "Set MCP_PUBLIC_URL + MCP_OAUTH_PASSWORD (OAuth for Claude) " \
        "or MCP_AUTH_TOKEN (bearer for mcp-remote).",
      )
    end
    build_http_app.run!
  end
end
