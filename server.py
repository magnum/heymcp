"""MCP server wrapping the HEY CLI (https://github.com/basecamp/hey-cli).

Transport is selected via MCP_TRANSPORT:
  - "http"  (default) streamable HTTP, for use across the LAN
  - "stdio"           for local testing with `docker run -i`

Auth modes (HTTP):
  - OAuth (Claude Custom Connector): set MCP_PUBLIC_URL + password
  - Bearer token (mcp-remote --header): set MCP_AUTH_TOKEN without MCP_PUBLIC_URL,
    or set MCP_AUTH_MODE=bearer

Write tools are gated:
  - HEY_ALLOW_SEND=true   → compose, reply
  - HEY_ALLOW_WRITE=true  → seen/unseen, todos, habits, timetrack start/stop, journal write
"""

from __future__ import annotations

import os
import re
import secrets
from pathlib import Path

from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions, RevocationOptions
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import AnyHttpUrl
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

import hey_client
from hey_client import HeyError
from oauth_provider import SCOPE, SimpleOAuthProvider

TOKEN = os.environ.get("MCP_AUTH_TOKEN", "")
TRANSPORT = os.environ.get("MCP_TRANSPORT", "http").lower()
ALLOW_SEND = os.environ.get("HEY_ALLOW_SEND", "true").lower() == "true"
ALLOW_WRITE = os.environ.get("HEY_ALLOW_WRITE", "true").lower() == "true"
HOST = os.environ.get("MCP_HOST", "0.0.0.0")
PORT = int(os.environ.get("MCP_PORT", "8765"))
PUBLIC_URL = os.environ.get("MCP_PUBLIC_URL", "").rstrip("/")
AUTH_MODE = os.environ.get("MCP_AUTH_MODE", "").lower()  # oauth | bearer | auto
OAUTH_USERNAME = os.environ.get("MCP_OAUTH_USERNAME", "admin")
OAUTH_PASSWORD = os.environ.get("MCP_OAUTH_PASSWORD") or TOKEN

# DNS rebinding protection: Host must be allowlisted when behind Cloudflare/proxy.
_raw_hosts = os.environ.get("MCP_ALLOWED_HOSTS", "localhost,127.0.0.1")
_allowed_hosts: list[str] = []
for h in (x.strip() for x in _raw_hosts.split(",") if x.strip()):
    _allowed_hosts.append(h)
    if ":" not in h.strip("[]"):
        _allowed_hosts.append(f"{h}:*")

_raw_origins = os.environ.get("MCP_ALLOWED_ORIGINS", "")
_allowed_origins = [o.strip() for o in _raw_origins.split(",") if o.strip()]
if not _allowed_origins:
    for h in (x.strip() for x in _raw_hosts.split(",") if x.strip()):
        base = h.split(":")[0] if not h.startswith("[") else h
        _allowed_origins.extend([f"https://{base}", f"http://{base}"])
if PUBLIC_URL:
    _allowed_origins.append(PUBLIC_URL)

_transport_security = TransportSecuritySettings(
    enable_dns_rebinding_protection=True,
    allowed_hosts=_allowed_hosts,
    allowed_origins=_allowed_origins,
)


def _oauth_enabled() -> bool:
    if AUTH_MODE == "bearer":
        return False
    if AUTH_MODE == "oauth":
        return True
    # auto: OAuth when public URL + password are configured
    return bool(PUBLIC_URL and OAUTH_PASSWORD)


oauth_provider: SimpleOAuthProvider | None = None
_auth_kwargs: dict = {}

if _oauth_enabled():
    if not PUBLIC_URL:
        raise SystemExit("MCP_PUBLIC_URL is required for OAuth (e.g. https://heymcp.example.com)")
    if not OAUTH_PASSWORD:
        raise SystemExit("Set MCP_OAUTH_PASSWORD or MCP_AUTH_TOKEN for OAuth login")

    oauth_provider = SimpleOAuthProvider(
        username=OAUTH_USERNAME,
        password=OAUTH_PASSWORD,
        public_url=PUBLIC_URL,
        static_bearer=TOKEN or None,
    )
    _auth_kwargs = {
        "auth_server_provider": oauth_provider,
        "auth": AuthSettings(
            issuer_url=AnyHttpUrl(PUBLIC_URL),
            resource_server_url=AnyHttpUrl(f"{PUBLIC_URL}/mcp"),
            client_registration_options=ClientRegistrationOptions(
                enabled=True,
                valid_scopes=[SCOPE],
                default_scopes=[SCOPE],
            ),
            revocation_options=RevocationOptions(enabled=True),
            required_scopes=[SCOPE],
        ),
    }

mcp = FastMCP(
    "hey",
    host=HOST if HOST != "0.0.0.0" else "127.0.0.1",
    instructions=(
        "HEY email MCP. Before complex workflows call hey_skill. "
        "For hey_compose / hey_reply ALWAYS pass `paragraphs` as an array of short "
        "paragraphs (greeting, body blocks, numbered options, closing, signature). "
        "Never send the whole email as one unbroken line in `message`."
    ),
    stateless_http=True,
    transport_security=_transport_security,
    **_auth_kwargs,
)


@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_request: Request) -> Response:
    return JSONResponse(
        {
            "status": "ok",
            "send_enabled": ALLOW_SEND,
            "write_enabled": ALLOW_WRITE,
            "auth": "oauth+bearer" if oauth_provider and TOKEN else ("oauth" if oauth_provider else "bearer"),
            "public_url": PUBLIC_URL or None,
        }
    )


if oauth_provider is not None:

    @mcp.custom_route("/login", methods=["GET"])
    async def login_page(request: Request) -> Response:
        state = request.query_params.get("state")
        if not state:
            return JSONResponse({"error": "missing state"}, status_code=400)
        return await oauth_provider.get_login_page(state)

    @mcp.custom_route("/login/callback", methods=["POST"])
    async def login_callback(request: Request) -> Response:
        return await oauth_provider.handle_login_callback(request)


async def _call(args: list[str]) -> str:
    try:
        return await hey_client.run(args)
    except HeyError as exc:
        return f"ERROR: {exc}"


def _require(value: str, name: str) -> str | None:
    value = value.strip()
    if not value:
        return f"ERROR: {name} is required"
    return None


def _gate(enabled: bool, flag: str) -> str | None:
    if enabled:
        return None
    return f"ERROR: disabled. Set {flag}=true in .env and restart."


def _email_body(message: str | None, paragraphs: list[str] | None) -> str | None:
    """Build a readable plain-text body. Prefer paragraphs (joined with blank lines)."""
    if paragraphs:
        parts = [p.strip() for p in paragraphs if p and p.strip()]
        if parts:
            return "\n\n".join(parts)
    if message and message.strip():
        # Soft fix: if the model sent one huge line, break after sentence ends
        # followed by a capital letter — last resort only.
        text = message.strip()
        if "\n" not in text and len(text) > 280:
            text = re.sub(r"([.!?])\s+(?=[A-ZÀ-ÖØ-Þ0-9])", r"\1\n\n", text)
        return text
    return None


def _skill_text() -> str:
    for candidate in (
        Path(__file__).resolve().parent / "skills" / "hey" / "SKILL.md",
        Path("/app/skills/hey/SKILL.md"),
    ):
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8")
    return "SKILL.md not found in image. See https://github.com/basecamp/hey-cli/blob/main/skills/hey/SKILL.md"


# --- Skill (vendored from hey-cli) ------------------------------------------


@mcp.resource("hey://skill")
def hey_skill_resource() -> str:
    """Official HEY CLI agent skill (workflows, ID rules, command reference)."""
    return _skill_text()


@mcp.tool()
async def hey_skill() -> str:
    """Return the HEY CLI agent skill: decision trees, ID rules (topic_id vs posting id), and command reference.

    Read this before complex HEY workflows.
    """
    return _skill_text()


# --- Auth & diagnostics ----------------------------------------------------


@mcp.tool()
async def hey_auth_status() -> str:
    """Check whether the hey CLI is authenticated with HEY (`hey auth status --json`)."""
    return await _call(hey_client.cmd_auth_status())


@mcp.tool()
async def hey_auth_token() -> str:
    """Print the HEY access token (`hey auth token --quiet`). Sensitive — only when needed."""
    return await _call(hey_client.cmd_auth_token())


@mcp.tool()
async def hey_doctor() -> str:
    """Check hey CLI system health and configuration (`hey doctor --json`)."""
    return await _call(hey_client.cmd_doctor())


@mcp.tool()
async def hey_config_show() -> str:
    """Show hey CLI configuration and sources (`hey config show --json`)."""
    return await _call(hey_client.cmd_config_show())


# --- Email -----------------------------------------------------------------


@mcp.tool()
async def hey_boxes(limit: int | None = None, fetch_all: bool = False) -> str:
    """List HEY mailboxes (`hey boxes --json`). Names: imbox, feedbox, trailbox, asidebox, laterbox, bubblebox.

    Args:
        limit: max boxes.
        fetch_all: pass --all (ignore limit).
    """
    return await _call(hey_client.cmd_boxes(limit, fetch_all=fetch_all))


@mcp.tool()
async def hey_box(
    name_or_id: str = "imbox",
    limit: int | None = 20,
    fetch_all: bool = False,
) -> str:
    """List postings in a mailbox (`hey box <name|id> --json`).

    Each posting has `id` (posting ID for seen/unseen) and `topic_id` (for threads/reply).

    Args:
        name_or_id: mailbox name or numeric ID.
        limit: max postings (default 20).
        fetch_all: pass --all.
    """
    if err := _require(name_or_id, "name_or_id"):
        return err
    return await _call(hey_client.cmd_box(name_or_id.strip(), limit, fetch_all=fetch_all))


@mcp.tool()
async def hey_threads(topic_id: str, html: bool = False) -> str:
    """Read a full email thread (`hey threads <topic_id> --json`). Use topic_id from hey_box, not posting id.

    Args:
        topic_id: topic ID.
        html: also request --html content when supported.
    """
    if err := _require(topic_id, "topic_id"):
        return err
    return await _call(hey_client.cmd_threads(topic_id.strip(), html=html))


@mcp.tool()
async def hey_drafts(limit: int | None = None, fetch_all: bool = False) -> str:
    """List drafts (`hey drafts --json`).

    Args:
        limit: max drafts.
        fetch_all: pass --all.
    """
    return await _call(hey_client.cmd_drafts(limit, fetch_all=fetch_all))


@mcp.tool()
async def hey_compose(
    subject: str,
    paragraphs: list[str] | None = None,
    message: str | None = None,
    to: str | None = None,
    cc: str | None = None,
    bcc: str | None = None,
    thread_id: str | None = None,
) -> str:
    """Compose/send email. Confirm with the user first.

    Body formatting (MANDATORY): pass `paragraphs` — one string per paragraph /
    list item / signature. They are joined with blank lines. Do NOT put the
    entire email in a single run-on `message` string.

    Args:
        subject: required subject.
        paragraphs: preferred body as list of paragraphs (joined with \\n\\n).
        message: fallback single body only for one short sentence; prefer paragraphs.
        to: recipient(s).
        cc: CC recipient(s).
        bcc: BCC recipient(s).
        thread_id: post into existing thread instead of/in addition to to.
    """
    if err := _gate(ALLOW_SEND, "HEY_ALLOW_SEND"):
        return err
    if err := _require(subject, "subject"):
        return err
    body = _email_body(message, paragraphs)
    if not body:
        return "ERROR: provide paragraphs (preferred) or message"
    if not (to and to.strip()) and not (thread_id and thread_id.strip()):
        return "ERROR: provide to and/or thread_id"
    return await _call(
        hey_client.cmd_compose(
            subject=subject.strip(),
            message=body,
            to=to.strip() if to else None,
            cc=cc.strip() if cc else None,
            bcc=bcc.strip() if bcc else None,
            thread_id=thread_id.strip() if thread_id else None,
        )
    )


@mcp.tool()
async def hey_reply(
    topic_id: str,
    paragraphs: list[str] | None = None,
    message: str | None = None,
) -> str:
    """Reply to a thread. Confirm with the user first.

    Body formatting (MANDATORY): pass `paragraphs` as an array of short paragraphs
    (greeting, points, closing, signature). Joined with blank lines. Avoid one
    long unbroken `message`.

    Args:
        topic_id: topic ID from hey_box.
        paragraphs: preferred body as list of paragraphs.
        message: fallback for a one-line reply only.
    """
    if err := _gate(ALLOW_SEND, "HEY_ALLOW_SEND"):
        return err
    if err := _require(topic_id, "topic_id"):
        return err
    body = _email_body(message, paragraphs)
    if not body:
        return "ERROR: provide paragraphs (preferred) or message"
    return await _call(hey_client.cmd_reply(topic_id.strip(), body))


@mcp.tool()
async def hey_seen(posting_ids: list[str]) -> str:
    """Mark posting(s) as seen (`hey seen <id>...`). Use posting id from hey_box, not topic_id.

    Args:
        posting_ids: one or more posting IDs.
    """
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    ids = [p.strip() for p in posting_ids if p and p.strip()]
    if not ids:
        return "ERROR: posting_ids is required"
    return await _call(hey_client.cmd_seen(ids))


@mcp.tool()
async def hey_unseen(posting_ids: list[str]) -> str:
    """Mark posting(s) as unseen (`hey unseen <id>...`). Use posting id from hey_box.

    Args:
        posting_ids: one or more posting IDs.
    """
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    ids = [p.strip() for p in posting_ids if p and p.strip()]
    if not ids:
        return "ERROR: posting_ids is required"
    return await _call(hey_client.cmd_unseen(ids))


# --- Calendar & todos ------------------------------------------------------


@mcp.tool()
async def hey_calendars() -> str:
    """List calendars (`hey calendars --json`) → [{id, name, kind}, ...]."""
    return await _call(hey_client.cmd_calendars())


@mcp.tool()
async def hey_recordings(
    calendar_id: str,
    starts_on: str | None = None,
    ends_on: str | None = None,
    limit: int | None = None,
    fetch_all: bool = False,
) -> str:
    """List calendar recordings (`hey recordings <id> --json`). Grouped by Calendar::Event / Habit / Todo.

    Args:
        calendar_id: from hey_calendars.
        starts_on: YYYY-MM-DD (default today).
        ends_on: YYYY-MM-DD.
        limit: max per type.
        fetch_all: pass --all.
    """
    if err := _require(calendar_id, "calendar_id"):
        return err
    return await _call(
        hey_client.cmd_recordings(
            calendar_id.strip(),
            starts_on=starts_on,
            ends_on=ends_on,
            limit=limit,
            fetch_all=fetch_all,
        )
    )


@mcp.tool()
async def hey_todo_list(limit: int | None = None, fetch_all: bool = False) -> str:
    """List todos (`hey todo list --json`)."""
    return await _call(hey_client.cmd_todo_list(limit, fetch_all=fetch_all))


@mcp.tool()
async def hey_todo_add(title: str, date: str | None = None) -> str:
    """Create a todo (`hey todo add "..."`).

    Args:
        title: todo title.
        date: optional due date YYYY-MM-DD.
    """
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    if err := _require(title, "title"):
        return err
    return await _call(hey_client.cmd_todo_add(title.strip(), date))


@mcp.tool()
async def hey_todo_complete(todo_id: str) -> str:
    """Mark todo complete (`hey todo complete <id>`)."""
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    if err := _require(todo_id, "todo_id"):
        return err
    return await _call(hey_client.cmd_todo_complete(todo_id.strip()))


@mcp.tool()
async def hey_todo_uncomplete(todo_id: str) -> str:
    """Mark todo incomplete (`hey todo uncomplete <id>`)."""
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    if err := _require(todo_id, "todo_id"):
        return err
    return await _call(hey_client.cmd_todo_uncomplete(todo_id.strip()))


@mcp.tool()
async def hey_todo_delete(todo_id: str) -> str:
    """Delete a todo (`hey todo delete <id>`)."""
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    if err := _require(todo_id, "todo_id"):
        return err
    return await _call(hey_client.cmd_todo_delete(todo_id.strip()))


@mcp.tool()
async def hey_habit_complete(habit_id: str, date: str | None = None) -> str:
    """Complete a habit (`hey habit complete <id>`). IDs from hey_recordings Calendar::Habit.

    Args:
        habit_id: habit ID.
        date: optional YYYY-MM-DD (default today).
    """
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    if err := _require(habit_id, "habit_id"):
        return err
    return await _call(hey_client.cmd_habit_complete(habit_id.strip(), date))


@mcp.tool()
async def hey_habit_uncomplete(habit_id: str, date: str | None = None) -> str:
    """Uncomplete a habit (`hey habit uncomplete <id>`)."""
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    if err := _require(habit_id, "habit_id"):
        return err
    return await _call(hey_client.cmd_habit_uncomplete(habit_id.strip(), date))


@mcp.tool()
async def hey_timetrack_start() -> str:
    """Start time tracking (`hey timetrack start`)."""
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    return await _call(hey_client.cmd_timetrack_start())


@mcp.tool()
async def hey_timetrack_stop() -> str:
    """Stop time tracking (`hey timetrack stop`)."""
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    return await _call(hey_client.cmd_timetrack_stop())


@mcp.tool()
async def hey_timetrack_current() -> str:
    """Show current timer (`hey timetrack current --json`)."""
    return await _call(hey_client.cmd_timetrack_current())


@mcp.tool()
async def hey_timetrack_list(limit: int | None = None, fetch_all: bool = False) -> str:
    """List time tracks (`hey timetrack list --json`)."""
    return await _call(hey_client.cmd_timetrack_list(limit, fetch_all=fetch_all))


@mcp.tool()
async def hey_journal_list(limit: int | None = None, fetch_all: bool = False) -> str:
    """List journal entries (`hey journal list --json`)."""
    return await _call(hey_client.cmd_journal_list(limit, fetch_all=fetch_all))


@mcp.tool()
async def hey_journal_read(date: str | None = None, html: bool = False) -> str:
    """Read a journal entry (`hey journal read [date] --json`). Default: today.

    Args:
        date: optional YYYY-MM-DD.
        html: pass --html when supported.
    """
    return await _call(hey_client.cmd_journal_read(date, html=html))


@mcp.tool()
async def hey_journal_write(content: str, date: str | None = None) -> str:
    """Write a journal entry (`hey journal write -c "..."`). Default date: today.

    Args:
        content: journal text (required; no $EDITOR in MCP).
        date: optional YYYY-MM-DD.
    """
    if err := _gate(ALLOW_WRITE, "HEY_ALLOW_WRITE"):
        return err
    if err := _require(content, "content"):
        return err
    return await _call(hey_client.cmd_journal_write(content, date))


def build_http_app():
    """Streamable HTTP app. OAuth uses MCP SDK auth; bearer uses middleware."""
    from starlette.middleware.base import BaseHTTPMiddleware

    app = mcp.streamable_http_app()

    # Only when OAuth is off: protect everything except healthz with static bearer.
    if oauth_provider is None:

        class TokenAuth(BaseHTTPMiddleware):
            async def dispatch(self, request, call_next):
                if request.url.path == "/healthz":
                    return await call_next(request)
                if TOKEN:
                    header = request.headers.get("authorization", "")
                    if not secrets.compare_digest(header, f"Bearer {TOKEN}"):
                        return JSONResponse({"error": "unauthorized"}, status_code=401)
                return await call_next(request)

        app.add_middleware(TokenAuth)

    return app


app = build_http_app() if TRANSPORT == "http" else None


if __name__ == "__main__":
    if TRANSPORT == "stdio":
        mcp.run()
    else:
        if oauth_provider is None and not TOKEN:
            raise SystemExit(
                "Set MCP_PUBLIC_URL + MCP_OAUTH_PASSWORD (OAuth for Claude) "
                "or MCP_AUTH_TOKEN (bearer for mcp-remote)."
            )
        import uvicorn

        uvicorn.run(app, host=HOST, port=PORT, log_level="info", proxy_headers=True, forwarded_allow_ips="*")
