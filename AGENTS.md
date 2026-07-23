# AGENTS.md

## Cursor Cloud specific instructions

`heymcp` is a single Python service: an MCP server (`server.py`) that wraps the
Go `hey` CLI (from `github.com/basecamp/hey-cli`) and exposes its email/calendar/
todo/journal surface as MCP tools. There is no frontend and no test suite.

### Running the server (dev)

Docker is not used in this environment; run the server directly with Python.
The HTTP transport (default) refuses to start unless auth is configured, so an
`MCP_AUTH_TOKEN` (bearer) is required. `MCP_ALLOWED_HOSTS` must include the host
you connect as, or requests fail with `421 Invalid Host header`.

```bash
export MCP_AUTH_TOKEN=devtoken123
export MCP_ALLOWED_HOSTS=localhost,127.0.0.1
./.venv/bin/python server.py     # HTTP server on :8765
```

Health check: `curl -s http://127.0.0.1:8765/healthz`.
MCP endpoint is `POST /mcp` (streamable HTTP) and needs `Authorization: Bearer <MCP_AUTH_TOKEN>`.
For a quick no-Docker local check you can also run stdio: `MCP_TRANSPORT=stdio ./.venv/bin/python server.py`.

### The `hey` binary (non-obvious)

- The MCP server itself runs and serves `/healthz`, `hey_skill`, tools/list, etc.
  WITHOUT the `hey` binary. The binary is only invoked when a `hey_*` tool runs.
- The `hey` CLI is built from source (Go) and installed at `/usr/local/bin/hey`;
  it is baked into the VM snapshot, so it is NOT reinstalled by the update script.
  To rebuild it manually: `git clone --depth 1 https://github.com/basecamp/hey-cli`
  then `CGO_ENABLED=0 go build -o /tmp/hey ./cmd/hey` and `sudo install -m0755 /tmp/hey /usr/local/bin/hey`.
  (go.mod pins go 1.26.1 but it builds fine with the system Go 1.22.)
- Point the server at it explicitly if needed via `HEY_BIN=/usr/local/bin/hey`.

### Auth / testing limits

- `hey auth status` reports `authenticated: false` here because no HEY account is
  logged in. Email/calendar/todo tools that hit `app.hey.com` need a real HEY
  account authenticated via `hey auth login` (browser OAuth), which is not
  available in the sandbox. This is expected — it does not indicate a broken setup.
- Tools that work fully offline: `hey_skill` (returns vendored `skills/hey/SKILL.md`),
  plus any `hey_*` diagnostic that only shells out locally (e.g. `hey_auth_status`,
  `hey_doctor`, `hey_config_show`).

### Lint / tests / build

There is no linter config, no test suite, and no build step (pure Python + a
prebuilt Go binary). Syntax sanity: `./.venv/bin/python -m py_compile server.py hey_client.py oauth_provider.py`.
