# herdr-slack-inbox

A terminal inbox for Slack DMs and messages addressed to you. In a Herdr terminal it reports OSC 7501, so locally unread messages appear as **Needs you** in the Agents list.

## Requirements

- Ruby 3.4 or later, or a binary built with [Spinel](https://github.com/matz/spinel).
- `codex` on `PATH`, logged in, with the Slack plugin connected. Connect it through `/plugins` in Codex.
- A TTY for the interactive view. Without one, the program prints JSON Lines once and exits.

The program runs one persistent `codex app-server` child and calls Slack tools through `mcpServer/tool/call`. It starts an ephemeral thread but never starts a model turn. It stores no Slack token. Its tool allowlist contains only `slack_read_user_profile`, `slack_search_public_and_private`, `slack_read_thread`, and `slack_read_channel`. It does not send, react, edit, delete, join, or mark anything in Slack.

## Run

```sh
./bin/herdr-slack-inbox
./bin/herdr-slack-inbox --json
./bin/herdr-slack-inbox --interval=180 --days=3
```

The poll interval is 120 to 300 seconds; the default is 180. The first search goes back three days by default (`--days=1..30`). Each poll makes at most two Slack search calls: one for messages addressed to you and one for DMs. Results beyond the first page are loaded on later polls. A one-shot `--json` run prints the first page from each search. The next poll continues through any remaining pages. Slack search may rank or normalize messages in ways this program cannot control.

The DM search uses `filters: "is:dm"`, which returned DMs in the connected workspace during development. The mention search uses `filters: "<@your-user-id>"`, following the connected tool's search behavior. Both requests sort by timestamp and ask for detailed results. Detailed output includes channel IDs, message timestamps, and permalinks, which the concise format omits. The detailed output is still text rather than structured data. If its format changes, the parser shows an error instead of silently treating malformed entries as read.

For a Herdr terminal:

```sh
hc run --bg --keep --name slack-inbox -- herdr-slack-inbox
hc get slack-inbox --json
```

Put the script or compiled binary on `PATH` to use the command name. A terminal with an OSC 7501 status is an agent in Herdr. To place it in a particular space and tab, add the appropriate `herdr.space` and `herdr.tab` labels to `hc run`.

## Inbox behavior

**Unread means local unread.** Slack's plugin does not expose Slack's unread count or a mark-read operation. This program saves message IDs in `herdr-slack-inbox/seen.json` under `XDG_STATE_HOME` (default `~/.local/state`). Pressing `r` adds only the selected message to that file and removes it from the list immediately. It does not change Slack's read state. `o` opens the message permalink in Slack, where you can read it normally. It uses `open` on macOS and `xdg-open` elsewhere (chosen by OS, since `open` on Debian and Ubuntu can be `openvt`); set `HERDR_SLACK_INBOX_OPEN` to use another program.

The available read-only Slack tools do not expose whether you muted a channel. Press `m` on a message to exclude its channel locally. Exclusions are saved in `herdr-slack-inbox/excluded.json` under `XDG_CONFIG_HOME` (default `~/.config`). Press `M` to view excluded channels, then select one and press `m` to include it again. The inbox header shows how many currently fetched messages are hidden; the excluded-channel view shows the same count. Excluding a channel affects `--json` and the OSC status, but does not change Slack settings. If all fetched messages are excluded, the status is `idle`.

DMs appear first, followed by direct mention search results. Rows show the channel or DM participant, sender, relative age, and opening text. Selecting a row loads its thread on demand and caches it. The footer shows the last successful update, the next update, pagination, or an error. A connection or login error gives `state=blocked:kind=auth` and asks you to connect Slack through Codex `/plugins`. Other errors give `state=error`. Any visible local unread item gives `state=blocked:kind=question`; an empty inbox gives `state=idle`. OSC 7501 is emitted only when the state changes.

| Key | Action |
| --- | --- |
| `j` / `k` | Move through messages |
| `Enter` | Show the selected thread (also loaded when selected) |
| `r` | Mark the selected message locally read |
| `m` | Exclude the selected channel, or include it again in the excluded-channel view |
| `M` | Switch between the inbox and excluded-channel view |
| `o` | Open the message in Slack |
| `R` | Refresh now |
| `q` | Quit |

After `r`, no other row is selected. Press `j` or `k` to select another row. Repeated `r` cannot mark a different message. Search and thread reads run off the UI thread, so the interface remains responsive.

## Development

```sh
ruby -w test/inbox_test.rb
.spinel/bin/spinel bin/herdr-slack-inbox -o herdr-slack-inbox
INBOX_BIN=./herdr-slack-inbox ruby -w test/inbox_test.rb
```

Tests use a fake `codex app-server` and invented Slack content; they never call Slack. CI tests Ruby and the Spinel binary. `.spinel-version` pins the compiler, and `script/build-spinel.sh` builds it. Release tags starting with `v` build Linux and macOS archives. GitHub Actions dependencies are recorded in `.github/workflows/actions.lock`.

## License

MIT, see [LICENSE](LICENSE). Binary dependencies are listed in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
