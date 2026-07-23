# AGENTS.md

## Cursor Cloud specific instructions

### What this repo is
`heymcp` is a single Python service: an MCP server (`server.py`, built on FastMCP) that
exposes the [hey-cli](https://github.com/basecamp/hey-cli) surface as MCP tools. It shells
out to the Go `hey` binary via `hey_client.py`. There is no database or other service.

### Running the server locally (dev)
The update script creates `.venv` and installs `requirements.txt`. To run the server:

- `server.py` reads config from OS env vars — it does NOT auto-load `.env` (only
  `docker compose` does, via `env_file`). Export the vars before running, e.g.
  `set -a && . ./.env && set +a && . .venv/bin/activate && python server.py`.
- A local dev `.env` (bearer mode, gitignored) is expected. Minimum to boot in HTTP mode:
  set `MCP_AUTH_TOKEN` (server refuses to start in HTTP mode with neither OAuth nor a token).
  Keep `MCP_HOST=127.0.0.1` for local runs.
- Health: `curl -s http://127.0.0.1:8765/healthz`. MCP endpoint: `POST /mcp` (Streamable
  HTTP; requires `Authorization: Bearer $MCP_AUTH_TOKEN` — everything except `/healthz` is
  gated). Run it in a tmux session (long-running foreground process).
- stdio mode for local MCP clients: `MCP_TRANSPORT=stdio python server.py`.

### The `hey` CLI binary (external dependency)
- CLI-backed tools (`hey_boxes`, `hey_auth_status`, `hey_doctor`, ...) require the Go `hey`
  binary on `PATH` (`HEY_BIN`, default `hey`). Without it those tools return
  `ERROR: binary 'hey' not found in PATH`; the server and non-CLI tools still work.
- It is NOT installed by the update script (building it clones basecamp/hey-cli and needs the
  Go 1.26 toolchain — too brittle/network-heavy for startup). Build it on demand with
  `go build` (local `go` auto-fetches the 1.26 toolchain: `git clone --depth 1
  https://github.com/basecamp/hey-cli /tmp/hey-cli && cd /tmp/hey-cli && CGO_ENABLED=0 go
  build -trimpath -o /usr/local/bin/hey ./cmd/hey`) or via the provided `Dockerfile` (no
  Docker daemon is available in this VM by default). Set `HEY_NO_KEYRING=1` to avoid keyring
  warnings.
- Every `hey_*` tool that talks to HEY needs a real, authenticated HEY account
  (external paid SaaS at `app.hey.com`). Without a token the CLI runs but reports
  `authenticated: false`. Authenticate with `hey auth login --token <TOKEN>` (a valid HEY
  token is a user-provided secret). This cannot be mocked locally.

### Tests / lint / build
- There is no automated test suite and no configured linter (no ruff/flake8/pyproject).
  Closest sanity check: `python -m py_compile server.py hey_client.py oauth_provider.py`.
- There is no build step for the Python service. The `Dockerfile`/`docker-compose.yml`
  describe the production/container path and also build the `hey` CLI from source.

### Good hello-world (no HEY account needed)
Boot the server, then over the MCP protocol call the `hey_skill` tool — it returns the
vendored `skills/hey/SKILL.md` and needs no external auth. `hey_auth_status` additionally
exercises the real `hey` CLI (returns "Not logged in" without a HEY token).
