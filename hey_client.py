"""Thin adapter around the `hey` CLI (https://github.com/basecamp/hey-cli).

Command surface mirrors skills/hey/SKILL.md. Prefer `--json` for structured output.
"""

from __future__ import annotations

import asyncio
import os
import shutil
from typing import Sequence

HEY_BIN = os.environ.get("HEY_BIN", "hey")
TIMEOUT = int(os.environ.get("HEY_TIMEOUT", "30"))
MAX_CHARS = int(os.environ.get("HEY_MAX_CHARS", "12000"))


class HeyError(RuntimeError):
    """Raised when the CLI is missing, times out, or exits non-zero."""


def _truncate(text: str) -> str:
    if len(text) <= MAX_CHARS:
        return text
    return text[:MAX_CHARS] + f"\n\n[... truncated, {len(text) - MAX_CHARS} chars omitted]"


def _json(*parts: str) -> list[str]:
    return [*parts, "--json"]


def _opt_limit(args: list[str], limit: int | None, *, fetch_all: bool = False) -> list[str]:
    if fetch_all:
        args.append("--all")
    elif limit is not None:
        args.extend(["--limit", str(max(1, min(limit, 500)))])
    return args


def _opt_html(args: list[str], html: bool) -> list[str]:
    if html:
        args.append("--html")
    return args


# --- Email -----------------------------------------------------------------


def cmd_boxes(limit: int | None = None, *, fetch_all: bool = False) -> list[str]:
    return _opt_limit(_json("boxes"), limit, fetch_all=fetch_all)


def cmd_box(
    name_or_id: str,
    limit: int | None = None,
    *,
    fetch_all: bool = False,
) -> list[str]:
    return _opt_limit(_json("box", name_or_id), limit, fetch_all=fetch_all)


def cmd_threads(topic_id: str, *, html: bool = False) -> list[str]:
    return _opt_html(_json("threads", topic_id), html)


def cmd_drafts(limit: int | None = None, *, fetch_all: bool = False) -> list[str]:
    return _opt_limit(_json("drafts"), limit, fetch_all=fetch_all)


def cmd_compose(
    *,
    subject: str,
    message: str,
    to: str | None = None,
    cc: str | None = None,
    bcc: str | None = None,
    thread_id: str | None = None,
) -> list[str]:
    args = ["compose", "--subject", subject, "-m", message]
    if to:
        args.extend(["--to", to])
    if cc:
        args.extend(["--cc", cc])
    if bcc:
        args.extend(["--bcc", bcc])
    if thread_id:
        args.extend(["--thread-id", thread_id])
    args.append("--json")
    return args


def cmd_reply(topic_id: str, message: str) -> list[str]:
    return ["reply", topic_id, "-m", message, "--json"]


def cmd_seen(posting_ids: Sequence[str]) -> list[str]:
    return ["seen", *posting_ids, "--json"]


def cmd_unseen(posting_ids: Sequence[str]) -> list[str]:
    return ["unseen", *posting_ids, "--json"]


# --- Calendar & tasks ------------------------------------------------------


def cmd_calendars() -> list[str]:
    return _json("calendars")


def cmd_recordings(
    calendar_id: str,
    *,
    starts_on: str | None = None,
    ends_on: str | None = None,
    limit: int | None = None,
    fetch_all: bool = False,
) -> list[str]:
    args = _json("recordings", calendar_id)
    if starts_on:
        args.extend(["--starts-on", starts_on])
    if ends_on:
        args.extend(["--ends-on", ends_on])
    return _opt_limit(args, limit, fetch_all=fetch_all)


def cmd_todo_list(limit: int | None = None, *, fetch_all: bool = False) -> list[str]:
    return _opt_limit(_json("todo", "list"), limit, fetch_all=fetch_all)


def cmd_todo_add(title: str, date: str | None = None) -> list[str]:
    args = ["todo", "add", title]
    if date:
        args.extend(["--date", date])
    args.append("--json")
    return args


def cmd_todo_complete(todo_id: str) -> list[str]:
    return _json("todo", "complete", todo_id)


def cmd_todo_uncomplete(todo_id: str) -> list[str]:
    return _json("todo", "uncomplete", todo_id)


def cmd_todo_delete(todo_id: str) -> list[str]:
    return _json("todo", "delete", todo_id)


def cmd_habit_complete(habit_id: str, date: str | None = None) -> list[str]:
    args = ["habit", "complete", habit_id]
    if date:
        args.extend(["--date", date])
    args.append("--json")
    return args


def cmd_habit_uncomplete(habit_id: str, date: str | None = None) -> list[str]:
    args = ["habit", "uncomplete", habit_id]
    if date:
        args.extend(["--date", date])
    args.append("--json")
    return args


def cmd_timetrack_start() -> list[str]:
    return _json("timetrack", "start")


def cmd_timetrack_stop() -> list[str]:
    return _json("timetrack", "stop")


def cmd_timetrack_current() -> list[str]:
    return _json("timetrack", "current")


def cmd_timetrack_list(limit: int | None = None, *, fetch_all: bool = False) -> list[str]:
    return _opt_limit(_json("timetrack", "list"), limit, fetch_all=fetch_all)


def cmd_journal_list(limit: int | None = None, *, fetch_all: bool = False) -> list[str]:
    return _opt_limit(_json("journal", "list"), limit, fetch_all=fetch_all)


def cmd_journal_read(date: str | None = None, *, html: bool = False) -> list[str]:
    args = ["journal", "read"]
    if date:
        args.append(date)
    args.append("--json")
    return _opt_html(args, html)


def cmd_journal_write(content: str, date: str | None = None) -> list[str]:
    args = ["journal", "write"]
    if date:
        args.append(date)
    args.extend(["-c", content, "--json"])
    return args


# --- Auth & diagnostics ----------------------------------------------------


def cmd_auth_status() -> list[str]:
    return _json("auth", "status")


def cmd_auth_token() -> list[str]:
    return ["auth", "token", "--quiet"]


def cmd_doctor() -> list[str]:
    return _json("doctor")


def cmd_config_show() -> list[str]:
    return _json("config", "show")


async def run(args: list[str]) -> str:
    """Execute `hey <args>` and return stdout, truncated."""
    if shutil.which(HEY_BIN) is None:
        raise HeyError(f"binary '{HEY_BIN}' not found in PATH")

    proc = await asyncio.create_subprocess_exec(
        HEY_BIN,
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise HeyError(f"timeout after {TIMEOUT}s: hey {' '.join(args)}")

    if proc.returncode != 0:
        detail = stderr.decode(errors="replace").strip()[:500]
        if not detail:
            detail = stdout.decode(errors="replace").strip()[:500] or "no stderr"
        raise HeyError(f"hey exited {proc.returncode}: {detail}")

    return _truncate(stdout.decode(errors="replace").strip())
