# heymcp

Talk to your [HEY](https://hey.com) email from Claude, Cursor, or any MCP client.

A self-hosted MCP server (Ruby + Docker) wrapping the official [hey-cli](https://github.com/basecamp/hey-cli) — real OAuth against `app.hey.com`, not a browser scrape.

**What you get:** read mailboxes and threads, compose/reply, mark seen/unseen, manage todos, habits, calendar, time tracking, and journal — 29 tools in total.

## Quick start

```bash
git clone https://github.com/magnum/heymcp && cd heymcp

# 1. Config: a bearer token is the minimum
cp .env.example .env
echo "MCP_AUTH_TOKEN=$(openssl rand -hex 32)" >> .env

# 2. Build & run
docker compose up -d --build

# 3. Log the CLI into HEY (grab the token on any machine where `hey` is logged in: `hey auth token --quiet`)
docker compose run --rm --no-deps hey-mcp hey auth login --token "PASTE_TOKEN_HERE"

# Verify
curl -s http://127.0.0.1:8765/healthz
docker compose exec hey-mcp hey auth status
```

Then point your MCP client at `http://<host>:8765/mcp` with header `Authorization: Bearer <MCP_AUTH_TOKEN>`:

```bash
claude mcp add --transport http heymcp http://<host>:8765/mcp \
  --header "Authorization: Bearer $MCP_AUTH_TOKEN"
```

That's it. Everything below is optional depth.

---

<details>
<summary><strong>All tools</strong></summary>

| Area | Tools |
|------|--------|
| Skill | `hey_skill` |
| Auth / diagnostics | `hey_auth_status`, `hey_auth_token`, `hey_doctor`, `hey_config_show` |
| Email | `hey_boxes`, `hey_box`, `hey_threads`, `hey_drafts`, `hey_compose`, `hey_reply`, `hey_seen`, `hey_unseen` |
| Calendar | `hey_calendars`, `hey_recordings` |
| Todos | `hey_todo_list`, `hey_todo_add`, `hey_todo_complete`, `hey_todo_uncomplete`, `hey_todo_delete` |
| Habits | `hey_habit_complete`, `hey_habit_uncomplete` |
| Time | `hey_timetrack_start`, `hey_timetrack_stop`, `hey_timetrack_current`, `hey_timetrack_list` |
| Journal | `hey_journal_list`, `hey_journal_read`, `hey_journal_write` |

**IDs:** `hey_box` returns posting `id` (for seen/unseen) and `topic_id` (for threads/reply).

The official hey-cli agent skill is vendored and exposed as resource `hey://skill` and tool `hey_skill` — agents should read it before complex workflows.

</details>

<details>
<summary><strong>Claude.ai Custom Connector (OAuth)</strong></summary>

Claude.ai custom connectors expect OAuth discovery, not a raw bearer. The server ships its own OAuth provider (login form + Dynamic Client Registration). Add to `.env`:

```bash
MCP_PUBLIC_URL=https://heymcp.example.com
MCP_ALLOWED_HOSTS=heymcp.example.com,localhost,127.0.0.1
MCP_OAUTH_USERNAME=admin
MCP_OAUTH_PASSWORD=pick_a_strong_password
MCP_AUTH_TOKEN=still_useful_for_curl   # optional API key alongside OAuth
```

```bash
docker compose up -d --build
curl -s https://heymcp.example.com/.well-known/oauth-authorization-server | head
```

In Claude → Settings → Connectors → Add custom connector:

- **URL:** `https://heymcp.example.com/mcp`
- Auth: OAuth (auto discovery)
- Sign in with `MCP_OAUTH_USERNAME` / `MCP_OAUTH_PASSWORD`

Notes:

- After tool schema changes, **delete and re-add** the connector so it refreshes `tools/list`.
- The static `MCP_AUTH_TOKEN` keeps working alongside OAuth (curl, `mcp-remote`).
- If the hostname is on the public internet, put Cloudflare Access (or similar) in front.

</details>

<details>
<summary><strong>Claude Desktop / mcp-remote (bearer)</strong></summary>

```json
{
  "mcpServers": {
    "hey": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "https://heymcp.example.com/mcp",
        "--header", "Authorization: Bearer YOUR_MCP_AUTH_TOKEN"
      ]
    }
  }
}
```

With OAuth enabled you can omit `--header` and let the client run the browser login.

</details>

<details>
<summary><strong>Configuration reference</strong></summary>

| Variable | Default | Purpose |
|----------|---------|---------|
| `MCP_AUTH_TOKEN` | — | Static bearer token (curl, mcp-remote) |
| `MCP_PUBLIC_URL` | — | Public https URL; enables OAuth when set with a password |
| `MCP_OAUTH_USERNAME` / `MCP_OAUTH_PASSWORD` | `admin` / falls back to `MCP_AUTH_TOKEN` | OAuth login form credentials |
| `MCP_AUTH_MODE` | `auto` | Force `oauth` or `bearer` |
| `MCP_ALLOWED_HOSTS` | `localhost,127.0.0.1` | Allowed `Host` headers (DNS-rebinding protection; missing host → `421`) |
| `MCP_TRANSPORT` | `http` | `http` or `stdio` |
| `MCP_PORT` | `8765` | Listen port |
| `HEY_ALLOW_SEND` | `true` | Kill switch for compose/reply |
| `HEY_ALLOW_WRITE` | `true` | Kill switch for seen/unseen, todos, habits, timetrack, journal write |
| `HEY_TIMEOUT` | `30` | CLI timeout (seconds) |
| `HEY_MAX_CHARS` | `12000` | Tool output truncation |

Default publish is `8765:8765`; prefer `127.0.0.1:8765:8765` if you terminate TLS elsewhere (e.g. Cloudflare Tunnel).

HEY credentials live in the Docker volume `hey-cli-config`. Anyone with Docker on that host can read your mail — lock down the `docker` group.

</details>

<details>
<summary><strong>Email formatting</strong></summary>

Prefer `paragraphs` on `hey_compose` / `hey_reply` (one string per paragraph; joined with `\n\n`) so agents don't send one run-on blob:

```json
{
  "to": "friend@example.com",
  "subject": "Hello",
  "paragraphs": ["Hi,", "Short paragraph one.", "Short paragraph two.", "— You"]
}
```

</details>

<details>
<summary><strong>Local development (no Docker)</strong></summary>

Requires Ruby 4.0.6 (see `.ruby-version`) and the `hey` CLI in `PATH`. Built on the official [MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk).

```bash
bundle install
MCP_TRANSPORT=stdio bundle exec ruby server.rb          # stdio
MCP_AUTH_TOKEN=dev bundle exec ruby server.rb           # http on :8765
```

</details>

## License

[MIT](LICENSE). Community project, not affiliated with Basecamp / HEY. Use at your own risk; respect HEY's terms and your own privacy threat model.
