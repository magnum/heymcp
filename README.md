# heymcp

MCP server that wraps the official [hey-cli](https://github.com/basecamp/hey-cli) so Claude, Cursor, and other MCP clients can talk to [HEY](https://hey.com).

Runs in Docker. Uses the real CLI (OAuth/token auth against `app.hey.com`) — not a reverse‑engineered browser scrape.

Repo: [github.com/magnum/heymcp](https://github.com/magnum/heymcp)

## Features

- Full hey-cli surface as MCP tools: mailboxes, threads, compose/reply, seen/unseen, calendars, todos, habits, time tracking, journal
- Vendored agent skill: resource `hey://skill` + tool `hey_skill` ([upstream skill](https://github.com/basecamp/hey-cli/blob/main/skills/hey/SKILL.md))
- Auth modes:
  - **OAuth** for Claude Custom Connectors (login form + Dynamic Client Registration)
  - **Static bearer** (`MCP_AUTH_TOKEN`) for curl / `mcp-remote` / Claude Code — works even when OAuth is enabled
- Email bodies via `paragraphs[]` (joined with blank lines) so agents don’t send one run-on blob
- Optional kill switches: `HEY_ALLOW_SEND` / `HEY_ALLOW_WRITE` (default `true`)

## Tools

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

## Quick start

### 1. HEY CLI auth (headless)

Authenticate somewhere with a browser, then inject the token into the container volume:

```bash
# on a machine where you're already logged in
hey auth token --quiet

# on the Docker host, in this repo
docker compose up -d --build

docker compose run --rm --no-deps \
  hey-mcp \
  hey auth login --token "PASTE_TOKEN_HERE"

docker compose up -d
docker compose exec hey-mcp hey auth status
```

Credentials live in the Docker volume `hey-cli-config` (no host `chmod` fights). Anyone with Docker on that host can read your mail — lock down the `docker` group.

### 2. Config

```bash
cp .env.example .env
# set MCP_AUTH_TOKEN, and for OAuth also MCP_PUBLIC_URL + MCP_OAUTH_*
```

Minimal `.env` for LAN / bearer-only:

```bash
MCP_AUTH_TOKEN=$(openssl rand -hex 32)
MCP_ALLOWED_HOSTS=localhost,127.0.0.1
HEY_ALLOW_SEND=true
HEY_ALLOW_WRITE=true
```

### 3. Run

```bash
docker compose up -d --build
curl -s http://127.0.0.1:8765/healthz
# {"status":"ok","send_enabled":true,"write_enabled":true,"auth":"..."}
```

Default publish: `8765:8765`. Prefer `127.0.0.1:8765:8765` if you terminate TLS elsewhere (e.g. Cloudflare Tunnel).

## Claude Custom Connector (OAuth)

Claude.ai custom connectors expect OAuth discovery, not a raw bearer.

```bash
MCP_PUBLIC_URL=https://heymcp.example.com
MCP_ALLOWED_HOSTS=heymcp.example.com,localhost,127.0.0.1
MCP_OAUTH_USERNAME=admin
MCP_OAUTH_PASSWORD=pick_a_strong_password
MCP_AUTH_TOKEN=still_useful_for_curl   # optional API key alongside OAuth
```

```bash
docker compose up -d --build
curl -s https://heymcp.example.com/healthz
curl -s https://heymcp.example.com/.well-known/oauth-authorization-server | head
```

In Claude → Settings → Connectors → Add custom connector:

- **URL:** `https://heymcp.example.com/mcp`
- Auth: OAuth (auto discovery)
- Sign in with `MCP_OAUTH_USERNAME` / `MCP_OAUTH_PASSWORD`

After tool schema changes, **delete and re-add** the connector so it refreshes `tools/list`.

Put Cloudflare Access (or similar) in front if the hostname is on the public internet. A bearer alone is not enough.

## Claude Desktop / Claude Code (bearer)

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

```bash
claude mcp add --transport http heymcp https://heymcp.example.com/mcp \
  --header "Authorization: Bearer $MCP_AUTH_TOKEN"
```

With OAuth enabled you can omit `--header` and let the client run the browser login.

## Compose formatting

Prefer `paragraphs` on `hey_compose` / `hey_reply` (one string per paragraph; joined with `\n\n`):

```json
{
  "to": "friend@example.com",
  "subject": "Hello",
  "paragraphs": [
    "Hi,",
    "Short paragraph one.",
    "Short paragraph two.",
    "— You"
  ]
}
```

## Local stdio (no Docker HTTP)

```bash
MCP_TRANSPORT=stdio python server.py
```

## Notes

- Built on official [hey-cli](https://github.com/basecamp/hey-cli); keep the CLI authenticated inside the container
- DNS-rebinding protection: list public hostnames in `MCP_ALLOWED_HOSTS` or you get `421 Invalid Host header`
- Tool output is truncated at `HEY_MAX_CHARS` (default 12000)
- This is a community project, not affiliated with Basecamp / HEY

## License

Use at your own risk. Respect HEY’s terms and your own privacy threat model.
