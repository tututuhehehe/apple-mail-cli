# Apple Mail CLI

A comprehensive command-line interface for macOS Mail.app — 33 commands for reading, sending, searching, organizing, bulk operations, and monitoring email.

Built with Bash and AppleScript. Zero dependencies beyond macOS built-in tools.

## Requirements

- **macOS 12+** (Monterey or later)
- **Mail.app** configured with at least one account
- **Bash 3.2+** (included with macOS)

## Quick Start

```bash
# Run any command
bash apple-mail.sh <command> [args...]

# Create a convenient alias
alias amail="bash /path/to/apple-mail.sh"

# List your accounts
amail accounts

# List all mailboxes with unread counts
amail folders

# List recent inbox messages
amail list 10

# List unread only
amail list --unread

# Read a specific email by ID
amail read 79132

# Search across all mailboxes
amail search "quarterly report" --mailbox all 20

# Send an email
amail send --to "colleague@example.com" --subject "Meeting" --body "See you at 3pm"

# Send with attachment
amail send --to "boss@company.com" --subject "Report" --body "Attached." --attach ~/report.pdf
```

## Example Output

```
$ amail list 5
ID:79132 [ ] [⚑]      | 2026-03-12 14:30 | From: alice@example.com    | Subject: Q1 Report Draft
ID:79128 [READ]        | 2026-03-12 10:15 | From: bob@company.com      | Subject: Meeting Tomorrow
ID:79125 [ ] [📎]      | 2026-03-11 16:45 | From: carol@client.com     | Subject: Contract Review
ID:79120 [READ] [📎]   | 2026-03-11 09:22 | From: dave@partner.com     | Subject: Invoice #1234
ID:79118 [READ]        | 2026-03-10 15:00 | From: eve@newsletter.com   | Subject: Weekly Digest
```

Legend: `[ ]` = unread, `[READ]` = read, `[⚑]` = flagged, `[📎]` = has attachments

```
$ amail unread
inbox: 3 unread
sent: 0 unread
```

```
$ amail search "report" --after 2026-03-01 --mailbox all 3
ID:79132 | 2026-03-12 14:30 | From: alice@example.com    | Subject: Q1 Report Draft
ID:79098 | 2026-03-05 11:00 | From: finance@company.com  | Subject: Expense Report Due
ID:79085 | 2026-03-02 09:15 | From: bob@company.com      | Subject: Annual Report Review
```

## Command Reference

### Reading

| Command | Aliases | Description |
|---------|---------|-------------|
| `list [N] [--mailbox box] [--unread]` | `ls` | List recent emails (default 10). `--unread` for unread only |
| `read <id> [--mailbox box]` | `show`, `view` | Read full email by ID |
| `unread [--mailbox box]` | `count-unread` | Count unread messages |
| `thread <id> [--mailbox box]` | `conversation` | List thread messages (headers) |
| `thread-read <id> [--mailbox box]` | `threadread` | Full thread with bodies, chronological |
| `attachments <id> [--mailbox box]` | `attach`, `att` | List attachments (name, MIME, size) |

### Searching

`search <query> [N] [options]` (aliases: `find`, `query`)

| Option | Description |
|--------|-------------|
| `--mailbox box` / `--mailbox all` | Target mailbox or search all |
| `--from addr` | Filter by sender |
| `--unread` | Unread only |
| `--body` | Search body too (slower) |
| `--after YYYY-MM-DD` | After date |
| `--before YYYY-MM-DD` | Before date |

### Composing

| Command | Aliases | Key Options |
|---------|---------|-------------|
| `send --to addr --subject s --body b` | `compose`, `new` | `--to` (repeatable), `--cc`, `--bcc`, `--from`, `--attach` (repeatable) |
| `reply <id> <body>` | `respond` | `--all`, `--mailbox`, `--cc`, `--bcc` |
| `reply-all <id> <body>` | `replyall` | Same as reply (`--all` implicit) |
| `forward <id> --to addr` | `fwd` | `--body` (prefix text), `--mailbox` |
| `draft --to addr --subject s --body b` | `save-draft` | `--cc` |

Short form: `send user@example.com "Subject" "Body"` also works.

### Organization

| Command | Aliases | Description |
|---------|---------|-------------|
| `flag <id> [--mailbox box]` | `star` | Flag email |
| `unflag <id> [--mailbox box]` | `unstar` | Remove flag |
| `mark-read <id> [--mailbox box]` | `markread` | Mark as read |
| `mark-unread <id> [--mailbox box]` | `markunread` | Mark as unread |
| `move <id> <dest> [--mailbox src]` | | Move to mailbox |
| `trash <id> [--mailbox box]` | `delete`, `rm` | Move to Trash |
| `archive <id> [--mailbox box]` | | Move to Archive |

### Bulk Operations

Three safety modes: (no flag) = **dry-run** | `--confirm` = interactive y/N prompt | `--force` = immediate execution

| Command | Key Options |
|---------|-------------|
| `bulk-trash --mailbox box [--unread-only] [--force]` | Trash all/unread in mailbox |
| `bulk-move --mailbox box --dest dest [--unread-only] [--force]` | Move between mailboxes |
| `bulk-mark-read --mailbox box [--force]` | Mark all as read |

### Attachments & Export

| Command | Aliases | Description |
|---------|---------|-------------|
| `save-attachment <id> [--mailbox box] [--out dir]` | `save-att` | Download attachments (default `~/Downloads/`) |
| `export <id> [--mailbox box] [--out path]` | `export-email` | Export to `.email.md` with YAML frontmatter |

### Watch / Monitor (Background New-Mail Alerts)

| Command | Description |
|---------|-------------|
| `watch start` | Start launchd monitoring (every 2 min) |
| `watch stop` | Stop monitoring |
| `watch status` | Show status, last check time, VIP count |
| `watch check` | Run a manual check now |
| `watch log [N]` | Show last N lines of watch log (default 30) |
| `watch vip` | Display VIP sender list |
| `watch vip-add <sender>` | Add a VIP sender (case-insensitive partial match) |

VIP senders get individual macOS notifications with sound. Regular mail gets batch summaries.

### Info

| Command | Aliases | Description |
|---------|---------|-------------|
| `accounts` | `accts` | List configured email accounts |
| `folders` | `mailboxes`, `boxes` | List all mailboxes with unread/total counts |

## Mailbox Names

- **System:** `inbox` (default), `sent`, `drafts`, `trash`, `junk`
- **Custom:** Exact folder name from `folders` output, e.g., `"Archive"`, `"Work/Projects"`
- **Hierarchical:** Use `/` for nested folders: `"Clients/Acme Corp"`

## Bulk Unsubscribe Tool

Included utility for bulk unsubscribing from mailing lists using RFC 8058 `List-Unsubscribe` headers:

```bash
# Dry-run (default — shows what would happen)
bash bulk-unsubscribe.sh --mailbox "Newsletters"

# Interactive with confirmation prompts
bash bulk-unsubscribe.sh --mailbox "Newsletters" --trash-after

# Limit to 20 emails
bash bulk-unsubscribe.sh --mailbox "Newsletters" --limit 20
```

Supports HTTP one-click unsubscribe and mailto unsubscribe methods. Logs all operations.

## Watch Setup

The watch system monitors your inbox for new mail and sends macOS notifications:

```bash
# 1. Set up your VIP list
cp watch-vip.txt.example watch-vip.txt
# Edit watch-vip.txt with your important contacts

# 2. Start monitoring
bash apple-mail.sh watch start

# 3. Check status
bash apple-mail.sh watch status
```

Optional: Set `VOICE_NOTIFY_ID` environment variable for voice notifications via an ElevenLabs TTS server on `localhost:8888`.

## Installation

```bash
# Clone the repository
git clone https://github.com/macos-cli-tools/apple-mail-cli.git
cd apple-mail-cli

# Run the installer (sets up alias)
bash install.sh

# Or manually add alias to your shell profile
echo 'alias amail="bash /path/to/apple-mail-cli/apple-mail.sh"' >> ~/.zshrc
```

## Testing

```bash
# Run the smoke test suite (read-only commands only)
bash test-apple-mail.sh
```

## Limitations

- **Plain text only** — HTML is stripped with a notice; rich formatting not preserved
- **Search** without `--body` matches subject and sender only (fast); add `--body` for full-text (slower)
- **Bulk operations** require `--mailbox`; use `--force` for automation
- **Watch** requires Mail.app to be running
- **Custom mailboxes** must match the exact name shown by `folders` command

## License

MIT — see [LICENSE](LICENSE).
