# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "json"
require "stringio"
require "pty"

load File.expand_path("../bin/herdr-slack-inbox", __dir__)

class InboxTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = ENV.fetch("INBOX_BIN", File.join(ROOT, "bin", "herdr-slack-inbox"))
  FAKE = File.join(ROOT, "test", "fixtures", "fake-codex")

  def setup
    @tmp = Dir.mktmpdir("slack-inbox-test")
    @log = File.join(@tmp, "calls.jsonl")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def env
    {"HERDR_SLACK_INBOX_CODEX" => FAKE, "FAKE_CODEX_LOG" => @log, "XDG_STATE_HOME" => @tmp, "XDG_CONFIG_HOME" => @tmp}
  end

  def exclusions
    HerdrSlackInbox::Exclusions.new(path: File.join(@tmp, "herdr-slack-inbox", "excluded.json"))
  end

  def test_json_cli_and_read_only_calls
    out, err, status = Open3.capture3(env, BIN, "--json")
    assert status.success?, err
    rows = out.lines.map { |line| JSON.parse(line) }
    assert_equal 3, rows.length
    assert_equal %w[dm mention mention], rows.map { |item| item["kind"] }
    assert rows.all? { |item| item["channel_id"] && item["ts"] && item["permalink"] && item["text"] }
    calls = File.readlines(@log).map { |line| JSON.parse(line) }
    assert_equal 1, calls.count { |call| call["method"] == "thread/start" }
    refute calls.any? { |call| call["method"].start_with?("turn/") }
    assert calls.filter_map { |call| call["tool"] }.all? { |tool| tool.match?(/\Aslack\.(?:slack_read_user_profile|slack_search_public_and_private)\z/) }
  end

  def test_mark_is_local_immediate_and_changes_status
    output = StringIO.new
    app = HerdrSlackInbox::AppServer.new(command: FAKE)
    ENV["FAKE_CODEX_LOG"] = @log
    seen = HerdrSlackInbox::Seen.new(path: File.join(@tmp, "seen.json"))
    inbox = HerdrSlackInbox::Inbox.new(app: app, seen: seen, exclusions: exclusions, output: output)
    inbox.fetch
    count = File.readlines(@log).length
    inbox.items.dup.each { |item| inbox.mark(item) }
    assert_equal count, File.readlines(@log).length
    assert_equal 0, inbox.items.length
    assert_includes output.string, "state=blocked:kind=question"
    assert_includes output.string, "state=idle"
    assert_equal 3, JSON.parse(File.read(File.join(@tmp, "seen.json"))).length
  ensure
    app&.close
    ENV.delete("FAKE_CODEX_LOG")
  end

  def test_rejects_write_tools
    app = HerdrSlackInbox::AppServer.new(command: FAKE)
    assert_raises(HerdrSlackInbox::Error) { app.tool("slack_send_message", {}) }
    assert_raises(HerdrSlackInbox::Error) { app.tool("slack_add_reaction", {}) }
    refute File.exist?(@log)
  ensure
    app&.close
  end

  def test_repeated_read_key_does_not_mark_next_row
    app = HerdrSlackInbox::AppServer.new(command: FAKE)
    ENV["FAKE_CODEX_LOG"] = @log
    inbox = HerdrSlackInbox::Inbox.new(app: app, seen: HerdrSlackInbox::Seen.new(path: File.join(@tmp, "seen.json")), exclusions: exclusions, output: StringIO.new, osc: false)
    inbox.fetch
    tui = HerdrSlackInbox::Tui.new(inbox, input: StringIO.new, output: StringIO.new)
    tui.send(:handle, "r", 0)
    tui.send(:handle, "r", 0)
    assert_equal 2, inbox.items.length
    assert_equal 1, JSON.parse(File.read(File.join(@tmp, "seen.json"))).length
    tui.send(:handle, "j", 0)
    assert_equal inbox.items.first, tui.send(:selected_item)
    tui.instance_variable_get(:@detail_thread)&.join
  ensure
    app&.close
    ENV.delete("FAKE_CODEX_LOG")
  end

  def test_excluding_channel_is_local_persistent_and_restorable
    app = HerdrSlackInbox::AppServer.new(command: FAKE)
    ENV["FAKE_CODEX_LOG"] = @log
    output = StringIO.new
    inbox = HerdrSlackInbox::Inbox.new(app: app, seen: HerdrSlackInbox::Seen.new(path: File.join(@tmp, "seen.json")), exclusions: exclusions, output: output)
    inbox.fetch
    count = File.readlines(@log).length
    mention = inbox.items.find { |item| item["kind"] == "mention" }
    inbox.exclude(mention)
    assert_equal count, File.readlines(@log).length
    assert_equal 2, inbox.excluded_count
    assert_equal ["dm"], inbox.items.map { |item| item["kind"] }
    assert_equal [["CEXAMPLE01", "#project-orchid"]], exclusions.channels
    inbox.include_channel("CEXAMPLE01")
    assert_equal 0, inbox.excluded_count
    assert_equal 3, inbox.items.length
    assert_includes output.string, "state=blocked:kind=question"
  ensure
    app&.close
    ENV.delete("FAKE_CODEX_LOG")
  end

  def test_tui_exclusion_management_restores_channel
    app = HerdrSlackInbox::AppServer.new(command: FAKE)
    ENV["FAKE_CODEX_LOG"] = @log
    inbox = HerdrSlackInbox::Inbox.new(app: app, seen: HerdrSlackInbox::Seen.new(path: File.join(@tmp, "seen.json")), exclusions: exclusions, output: StringIO.new, osc: false)
    inbox.fetch
    tui = HerdrSlackInbox::Tui.new(inbox, input: StringIO.new, output: StringIO.new)
    tui.send(:handle, "m", 0)
    assert_equal 1, inbox.excluded_count
    tui.send(:handle, "M", 0)
    tui.send(:handle, "m", 0)
    assert_equal 0, inbox.excluded_count
    assert_equal 3, inbox.items.length
  ensure
    app&.close
    ENV.delete("FAKE_CODEX_LOG")
  end

  def test_json_cli_respects_saved_exclusions
    exclusions.add("CEXAMPLE01", "#project-orchid")
    out, err, status = Open3.capture3(env, BIN, "--json")
    assert status.success?, err
    rows = out.lines.map { |line| JSON.parse(line) }
    assert_equal ["dm"], rows.map { |item| item["kind"] }
  end

  def test_excluding_every_channel_sets_idle_and_restoring_sets_blocked
    app = HerdrSlackInbox::AppServer.new(command: FAKE)
    ENV["FAKE_CODEX_LOG"] = @log
    output = StringIO.new
    inbox = HerdrSlackInbox::Inbox.new(app: app, seen: HerdrSlackInbox::Seen.new(path: File.join(@tmp, "seen.json")), exclusions: exclusions, output: output)
    inbox.fetch
    inbox.items.dup.each { |item| inbox.exclude(item) }
    assert_equal 0, inbox.items.length
    assert_equal 3, inbox.excluded_count
    assert_includes output.string, "state=idle"
    inbox.include_channel("DEXAMPLE01")
    assert_equal ["dm"], inbox.items.map { |item| item["kind"] }
    assert_equal 2, output.string.scan("state=blocked:kind=question").length
  ensure
    app&.close
    ENV.delete("FAKE_CODEX_LOG")
  end

  def test_parser_reports_changed_format
    response = {"content" => [{"type" => "text", "text" => JSON.generate({"results" => "# Search Results\n## Messages (1 results)\n### Unexpected\n"})}]}
    assert_raises(HerdrSlackInbox::ParseError) { HerdrSlackInbox::Parse.search(response, kind: "mention") }
  end

  def test_parser_keeps_multiline_body_and_dm_identity
    raw = File.read(File.join(ROOT, "test", "fixtures", "dm.json"))
    response = {"content" => [{"type" => "text", "text" => raw}]}
    items, cursor = HerdrSlackInbox::Parse.search(response, kind: "dm")
    assert_nil cursor
    assert_equal 1, items.length
    assert_equal "Casey Sample", items.first["channel"]
    assert_equal "DEXAMPLE01:1794794400.000003", items.first["id"]
    assert_includes items.first["text"], "Could you check"
  end

  def test_parser_handles_next_page_and_empty_results
    raw = JSON.parse(File.read(File.join(ROOT, "test", "fixtures", "mention.json")))
    raw["pagination_info"] = "For the next page of results use cursor `NEXT123`\n"
    response = {"content" => [{"type" => "text", "text" => JSON.generate(raw)}]}
    items, cursor = HerdrSlackInbox::Parse.search(response, kind: "mention")
    assert_equal 2, items.length
    assert_equal "NEXT123", cursor
    empty = {"content" => [{"type" => "text", "text" => JSON.generate({"results" => "# Search Results for: example\n\n## Messages (0 results)\n", "pagination_info" => "End of results"})}]}
    assert_equal [[], nil], HerdrSlackInbox::Parse.search(empty, kind: "mention")
  end

  def test_parser_rejects_missing_message_id
    raw = JSON.parse(File.read(File.join(ROOT, "test", "fixtures", "mention.json")))
    raw["results"] = raw["results"].sub(/Message_ts: [^\n]+/, "Message_ts: invalid")
    response = {"content" => [{"type" => "text", "text" => JSON.generate(raw)}]}
    assert_raises(HerdrSlackInbox::ParseError) { HerdrSlackInbox::Parse.search(response, kind: "mention") }
  end

  def test_rate_limits_are_unchanged_without_a_turn
    app = HerdrSlackInbox::AppServer.new(command: FAKE)
    ENV["FAKE_CODEX_LOG"] = @log
    before = app.rate_limits.dig("rateLimits", "individualLimit", "used")
    app.tool("slack_read_user_profile", {})
    after = app.rate_limits.dig("rateLimits", "individualLimit", "used")
    assert_equal before, after
    refute File.readlines(@log).any? { |line| line.include?("turn/start") }
  ensure
    app&.close
    ENV.delete("FAKE_CODEX_LOG")
  end

  # Runs the TUI in a pseudo terminal and presses o, with fake open and xdg-open first on PATH:
  # the program must pick the one for this OS (open on macOS, xdg-open elsewhere)
  def test_o_runs_the_opener_for_this_os
    bin = File.join(@tmp, "bin")
    FileUtils.mkdir_p(bin)
    opened = File.join(@tmp, "opened.txt")
    %w[open xdg-open].each do |name|
      path = File.join(bin, name)
      File.write(path, "#!/bin/sh\necho \"#{name} $1\" >> '#{opened}'\n")
      File.chmod(0o755, path)
    end
    child_env = env.merge("PATH" => "#{bin}:#{ENV.fetch("PATH")}")
    child_env.delete("HERDR_SLACK_INBOX_OPEN")
    expected = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"

    PTY.spawn(child_env, BIN) do |reader, writer, pid|
      screen = +""
      drain = Thread.new { loop { screen << reader.readpartial(4096) } rescue nil }
      deadline = Time.now + 15
      # The list is drawn once the first fetch has finished
      sleep 0.1 until screen.include?("Updated") || Time.now > deadline
      writer.write("o")
      sleep 0.1 until File.exist?(opened) || Time.now > deadline
      writer.write("q")
      Process.wait(pid)
      drain.kill
    end

    assert File.exist?(opened), "no opener ran"
    name, url = File.read(opened).split(" ", 2)
    assert_equal expected, name
    assert_match %r{\Ahttps://[^/]+\.slack\.com/archives/}, url.strip
  end

  # Runs the TUI in a pseudo terminal and presses j: the selected row's thread must be read and shown.
  # Catches `!@detail_thread`, which Spinel compiles to a constant false
  def test_selected_row_reads_its_thread
    PTY.spawn(env, BIN) do |reader, writer, pid|
      # Wide enough that the body line is not clipped
      reader.winsize = [30, 140]
      screen = +""
      drain = Thread.new { loop { screen << reader.readpartial(4096) } rescue nil }
      deadline = Time.now + 15
      sleep 0.1 until screen.include?("Updated") || Time.now > deadline
      writer.write("j")
      sleep 0.1 until screen.include?("Example message body") || Time.now > deadline
      writer.write("q")
      Process.wait(pid)
      drain.kill
      assert_includes screen, "Example message body"
    end

    assert_includes File.read(@log), "slack.slack_read_thread"
  end

  # A dropped connection to the Slack plugin comes back only with a new app-server
  def test_transport_error_restarts_the_app_server
    once = File.join(@tmp, "transport-once")
    out, err, status = Open3.capture3(env.merge("FAKE_CODEX_TRANSPORT_ONCE" => once), BIN, "--json")
    assert status.success?, err
    assert File.exist?(once), "the fake did not fail once"
    assert_equal 3, out.lines.length
    calls = File.readlines(@log).map { |line| JSON.parse(line) }
    assert_equal 2, calls.count { |call| call["method"] == "initialize" }
  end

  def search_arguments(extra_env = {})
    _out, err, status = Open3.capture3(env.merge(extra_env), BIN, "--json")
    assert status.success?, err
    File.readlines(@log).map { |line| JSON.parse(line) }
      .select { |call| call["tool"] == "slack.slack_search_public_and_private" }
      .to_h { |call| [call.dig("arguments", "filters") == "is:dm" ? "dm" : "mention", call["arguments"]] }
  end

  def test_mentions_come_only_from_channels_you_are_in
    args = search_arguments
    assert_equal true, args["mention"]["only_my_channels"]
    refute args["dm"].key?("only_my_channels")
  end

  def test_all_channels_setting_includes_channels_you_are_not_in
    args = search_arguments("HERDR_SLACK_INBOX_ALL_CHANNELS" => "1")
    refute args["mention"].key?("only_my_channels")
  end
end
