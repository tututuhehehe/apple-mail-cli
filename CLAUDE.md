# Apple Mail CLI — Claude Code Context

This file helps Claude Code understand and use the Apple Mail CLI effectively.

## Overview

Single-file Bash CLI (`apple-mail.sh`) providing 33 commands for macOS Mail.app via AppleScript.
Supplementary tools: `bulk-unsubscribe.sh` (mailing list unsubscribe), `watch-check.sh` (new mail monitor).

**Runtime:** Bash 3.2+ | **Platform:** macOS 12+ | **Backend:** AppleScript → Mail.app

## Running Commands

```bash
# Main CLI
bash apple-mail.sh <command> [args...]

# Bulk unsubscribe
bash bulk-unsubscribe.sh --mailbox "Newsletters" [--dry-run] [--trash-after]

# Smoke tests
bash test-apple-mail.sh
```

## Architecture

The CLI generates AppleScript dynamically and executes via `osascript`. Key internal patterns:

### Helper Functions

- **`osa_str()`** — Escapes strings for safe AppleScript embedding (backslash + quote escaping)
- **`mb_resolve()`** — Generates AppleScript to resolve a mailbox name to a mailbox object. Handles system mailboxes (inbox, sent, drafts, trash, junk) and custom mailboxes (searched across all accounts). Supports hierarchical paths up to 4 levels (`Clients/Acme/Active`).
- **`find_msg()`** — Generates AppleScript to find a message by ID within a resolved mailbox
- **`acct_for_mailbox()`** — Discovers which account owns a custom mailbox

### Critical AppleScript Constraints

1. **Handler-in-tell-block is illegal.** `on functionName()` cannot appear inside `tell application "Mail"`. Solution: bash helper functions that `printf` AppleScript code snippets, embedded via `$(command substitution)` in unquoted heredocs.
2. **`mailbox "Name" of acct_` does NOT work.** Use `first mailbox of acct_ whose name is "Name"` instead.
3. **Unquoted heredocs expand variables.** `<< OSAEOF` (not `<< 'OSAEOF'`) allows `$(mb_resolve ...)` substitution.

### Mailbox Resolution Pattern

```bash
osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")
    -- command AppleScript here
end tell
OSAEOF
```

## Command Categories (33 Total)

### Reading (6)
- `list [N] [--mailbox box] [--unread]` — Recent emails with status indicators
- `read <id> [--mailbox box]` — Full email content
- `unread [--mailbox box]` — Unread count
- `thread <id>` / `thread-read <id>` — Thread headers / full thread with bodies
- `attachments <id>` — List attachments

### Searching (1, with many options)
- `search <query> [N] [--mailbox box|all] [--from addr] [--unread] [--body] [--after date] [--before date]`

### Composing (5)
- `send`, `reply`, `reply-all`, `forward`, `draft`
- Send supports: `--to` (repeatable), `--cc`, `--bcc`, `--from`, `--attach` (repeatable)

### Organization (7)
- `flag`/`unflag`, `mark-read`/`mark-unread`, `move`, `trash`, `archive`

### Bulk Operations (3)
- `bulk-trash`, `bulk-move`, `bulk-mark-read`
- Safety modes: dry-run (default) → `--confirm` (interactive) → `--force` (automation)

### Attachments & Export (2)
- `save-attachment <id> [--out dir]` — Download to disk
- `export <id> [--out path]` — Export to Markdown with YAML frontmatter

### Watch / Monitor (7)
- `watch start|stop|status|check|log|vip|vip-add`
- Background monitoring via launchd, VIP priority alerting, macOS notifications

### Info (2)
- `accounts` — List email accounts
- `folders` — All mailboxes with counts

## Key Patterns

- **Mailbox `--mailbox` flag:** Most commands accept `--mailbox <name>` (alias `-m`). Default: `inbox`
- **Email ID:** Numeric Mail.app message ID, shown in `list` output as `ID:79132`
- **Bulk safety:** No flags = dry-run. `--confirm` = prompt. `--force` = execute (automation-safe)
- **Output format:** Tab-separated fields. `ID:` prefix on message IDs. Status indicators in brackets.

## File Layout

```
apple-mail-cli/
├── apple-mail.sh           # Main CLI (1,674 lines, 33 commands)
├── bulk-unsubscribe.sh     # RFC 8058 one-click unsubscribe tool
├── watch-check.sh          # Background new-mail monitor
├── watch-vip.txt.example   # VIP sender list template
├── test-apple-mail.sh      # Smoke test suite
├── install.sh              # Installer with alias setup
├── skill/SKILL.md          # Claude Code / AI agent skill definition
├── CLAUDE.md               # This file
├── README.md               # User documentation
├── CHANGELOG.md            # Version history
└── LICENSE                 # MIT
```

## State Locations

- **Watch cache:** `~/.cache/apple-mail-watch/` (last-check.json, watch.log)
- **Unsubscribe logs:** `~/.apple-mail-cli/logs/` (or `$UNSUBSCRIBE_LOG_DIR`)
- **VIP list:** `watch-vip.txt` in the install directory
- **launchd plist:** `~/Library/LaunchAgents/com.apple-mail-cli.watch.plist`

## Known Limitations

1. **Plain text only** — HTML emails are stripped; only text content is returned
2. **Search scope** — Without `--body`, searches subject + sender only (fast)
3. **Bulk ops** — Require `--mailbox`; cannot bulk-operate on inbox without explicit flag
4. **Watch** — Requires Mail.app running; checks every 2 minutes via launchd
5. **Hierarchical mailboxes** — Supports up to 4 levels deep (`A/B/C/D`)
6. **Account selection** — `--from` on send selects the from-account; defaults to first account
