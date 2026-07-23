# frozen_string_literal: true

# Thin adapter around the `hey` CLI (https://github.com/basecamp/hey-cli).
#
# Command surface mirrors skills/hey/SKILL.md. Prefer `--json` for structured output.

require "json"
require "open3"

module HeyClient
  BIN = ENV.fetch("HEY_BIN", "hey")
  TIMEOUT = ENV.fetch("HEY_TIMEOUT", "30").to_i
  MAX_CHARS = ENV.fetch("HEY_MAX_CHARS", "12000").to_i

  # Raised when the CLI is missing, times out, or exits non-zero.
  class HeyError < StandardError; end

  module_function

  def truncate(text)
    return text if text.length <= MAX_CHARS

    text[0, MAX_CHARS] + "\n\n[... truncated, #{text.length - MAX_CHARS} chars omitted]"
  end

  def json(*parts)
    [*parts, "--json"]
  end

  def opt_limit(args, limit, fetch_all: false)
    if fetch_all
      args << "--all"
    elsif limit
      args.push("--limit", limit.to_i.clamp(1, 500).to_s)
    end
    args
  end

  def opt_html(args, html)
    args << "--html" if html
    args
  end

  # --- Email ---------------------------------------------------------------

  def cmd_boxes(limit = nil, fetch_all: false)
    opt_limit(json("boxes"), limit, fetch_all: fetch_all)
  end

  def cmd_box(name_or_id, limit = nil, fetch_all: false)
    opt_limit(json("box", name_or_id), limit, fetch_all: fetch_all)
  end

  def cmd_threads(topic_id, html: false)
    opt_html(json("threads", topic_id), html)
  end

  def cmd_drafts(limit = nil, fetch_all: false)
    opt_limit(json("drafts"), limit, fetch_all: fetch_all)
  end

  def cmd_compose(subject:, message:, to: nil, cc: nil, bcc: nil, thread_id: nil)
    args = ["compose", "--subject", subject, "-m", message]
    args.push("--to", to) if to
    args.push("--cc", cc) if cc
    args.push("--bcc", bcc) if bcc
    args.push("--thread-id", thread_id) if thread_id
    args << "--json"
    args
  end

  def cmd_reply(topic_id, message)
    ["reply", topic_id, "-m", message, "--json"]
  end

  def cmd_seen(posting_ids)
    ["seen", *posting_ids, "--json"]
  end

  def cmd_unseen(posting_ids)
    ["unseen", *posting_ids, "--json"]
  end

  # --- Calendar & tasks ----------------------------------------------------

  def cmd_calendars
    json("calendars")
  end

  def cmd_recordings(calendar_id, starts_on: nil, ends_on: nil, limit: nil, fetch_all: false)
    args = json("recordings", calendar_id)
    args.push("--starts-on", starts_on) if starts_on
    args.push("--ends-on", ends_on) if ends_on
    opt_limit(args, limit, fetch_all: fetch_all)
  end

  def cmd_todo_list(limit = nil, fetch_all: false)
    opt_limit(json("todo", "list"), limit, fetch_all: fetch_all)
  end

  def cmd_todo_add(title, date = nil)
    args = ["todo", "add", title]
    args.push("--date", date) if date
    args << "--json"
    args
  end

  def cmd_todo_complete(todo_id)
    json("todo", "complete", todo_id)
  end

  def cmd_todo_uncomplete(todo_id)
    json("todo", "uncomplete", todo_id)
  end

  def cmd_todo_delete(todo_id)
    json("todo", "delete", todo_id)
  end

  def cmd_habit_complete(habit_id, date = nil)
    args = ["habit", "complete", habit_id]
    args.push("--date", date) if date
    args << "--json"
    args
  end

  def cmd_habit_uncomplete(habit_id, date = nil)
    args = ["habit", "uncomplete", habit_id]
    args.push("--date", date) if date
    args << "--json"
    args
  end

  def cmd_timetrack_start
    json("timetrack", "start")
  end

  def cmd_timetrack_stop
    json("timetrack", "stop")
  end

  def cmd_timetrack_current
    json("timetrack", "current")
  end

  def cmd_timetrack_list(limit = nil, fetch_all: false)
    opt_limit(json("timetrack", "list"), limit, fetch_all: fetch_all)
  end

  def cmd_journal_list(limit = nil, fetch_all: false)
    opt_limit(json("journal", "list"), limit, fetch_all: fetch_all)
  end

  def cmd_journal_read(date = nil, html: false)
    args = ["journal", "read"]
    args << date if date
    args << "--json"
    opt_html(args, html)
  end

  def cmd_journal_write(content, date = nil)
    args = ["journal", "write"]
    args << date if date
    args.push("-c", content, "--json")
    args
  end

  # --- Auth & diagnostics --------------------------------------------------

  def cmd_auth_status
    json("auth", "status")
  end

  def cmd_auth_token
    ["auth", "token", "--quiet"]
  end

  def cmd_doctor
    json("doctor")
  end

  def cmd_config_show
    json("config", "show")
  end

  def bin_available?
    return File.executable?(BIN) if BIN.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      File.executable?(File.join(dir, BIN))
    end
  end

  # --- JSON post-processing (MCP efficiency) --------------------------------
  #
  # Raw `hey box --json` postings weigh ~4 KB each (avatars, HTML signatures,
  # sync URLs...), so only ~3 fit in HEY_MAX_CHARS. These helpers project each
  # posting down to the fields an agent needs (~200 bytes), letting dozens of
  # emails fit in one response. They also add offset pagination and search,
  # which the CLI itself does not offer (only --limit / --all).

  TOPIC_ID_RE = %r{/topics/(\d+)}

  # Postings carry no topic_id field; it must be extracted from app_url.
  def posting_topic_id(posting)
    id = posting["topic_id"].to_s
    return id unless id.empty?

    posting["app_url"].to_s[TOPIC_ID_RE, 1].to_s
  end

  def compact_posting(posting)
    from = posting.dig("creator", "name").to_s
    from = posting["alternative_sender_name"].to_s if from.empty?
    contacts = Array(posting["contacts"]).map { |c| c["name"].to_s }.reject(&:empty?)

    row = {
      id: posting["id"],
      topic_id: posting_topic_id(posting),
      subject: posting["name"],
      from: from,
      date: posting["created_at"],
      seen: posting["seen"],
    }
    row[:contacts] = contacts.first(4).join(", ") if contacts.length > 2
    summary = posting["summary"].to_s.strip
    row[:summary] = summary[0, 120] unless summary.empty?
    row
  end

  def posting_matches?(posting, needle)
    haystack = [
      posting["name"],
      posting["summary"],
      posting["alternative_sender_name"],
      posting.dig("creator", "name"),
      *Array(posting["contacts"]).flat_map { |c| [c["name"], c["email_address"]] },
    ].compact.join("\n").downcase
    haystack.include?(needle)
  end

  def filter_postings(postings, query: nil, unseen_only: false, after: nil, before: nil)
    result = postings
    result = result.reject { |p| p["seen"] } if unseen_only
    if query && !query.strip.empty?
      needle = query.strip.downcase
      result = result.select { |p| posting_matches?(p, needle) }
    end
    if after || before
      result = result.select do |p|
        date = p["created_at"].to_s[0, 10]
        next false if date.empty?

        (after.nil? || date >= after) && (before.nil? || date <= before)
      end
    end
    result
  end

  # Turn a raw `hey box --json` envelope into a compact, paginated JSON string.
  def compact_box_json(raw, offset: 0, limit: 20, query: nil, unseen_only: false, after: nil, before: nil)
    env = JSON.parse(raw)
    data = env["data"] || {}
    postings = Array(data["postings"])
    matched = filter_postings(
      postings,
      query: query, unseen_only: unseen_only, after: after, before: before,
    )
    page = matched[offset, limit] || []

    rows = page.map { |p| compact_posting(p) }
    payload = nil
    note = "id → seen/unseen; topic_id → threads/reply"

    # Shrink the page row-by-row instead of cutting mid-string, so the JSON
    # stays valid; tell the agent where to resume.
    loop do
      payload = JSON.generate(
        box: data["name"],
        fetched: postings.length,
        matched: matched.length,
        offset: offset,
        count: rows.length,
        note: note,
        postings: rows,
      )
      break if payload.length <= MAX_CHARS || rows.empty?

      rows.pop
      note = "page shortened to fit output cap; continue with offset=#{offset + rows.length}"
    end
    payload
  rescue JSON::ParserError
    raw
  end

  # Execute `hey <args>` and return stdout, truncated unless the caller
  # post-processes the JSON itself.
  def run(args, truncate: true)
    raise HeyError, "binary '#{BIN}' not found in PATH" unless bin_available?

    Open3.popen3(BIN, *args) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }

      unless wait_thr.join(TIMEOUT)
        begin
          Process.kill("KILL", wait_thr.pid)
        rescue Errno::ESRCH
          # already gone
        end
        raise HeyError, "timeout after #{TIMEOUT}s: hey #{args.join(" ")}"
      end

      status = wait_thr.value
      out = out_reader.value.to_s
      err = err_reader.value.to_s

      unless status.success?
        detail = err.strip[0, 500]
        detail = out.strip[0, 500] if detail.empty?
        detail = "no stderr" if detail.empty?
        raise HeyError, "hey exited #{status.exitstatus}: #{detail}"
      end

      truncate ? self.truncate(out.strip) : out.strip
    end
  end
end
