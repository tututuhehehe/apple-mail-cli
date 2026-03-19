---
name: AppleMail
description: >
  Read, send, search, and reply to emails via macOS Mail.app (Apple Mail). USE WHEN user wants to
  check Apple Mail inbox or any folder, read an email, send email (with attachments),
  search emails (with date range), reply/reply-all/forward (with CC/BCC),
  flag/move/trash/archive emails, save attachments to disk, export to Markdown,
  bulk operations (bulk-trash, bulk-move, bulk-mark-read), thread-read with full bodies,
  check unread counts, OR list email accounts and folders. Differentiator -- 33-command bash
  script wrapping AppleScript for full Mail.app control including bulk ops, watch monitoring,
  and Markdown export.
---

# Apple Mail Skill

Bash + AppleScript CLI interface to macOS Mail.app.

**Primary script:** `INSTALL_DIR/apple-mail.sh`
**Requires:** macOS 12+, Mail.app configured with at least one account

> **Setup:** Replace `INSTALL_DIR` above (and in examples below) with the actual
> path where you cloned the repository. For example: `~/Projects/apple-mail-cli`

## Quick Reference

```bash
# Set this to your clone location
AMAIL="bash INSTALL_DIR/apple-mail.sh"

# Reading
$AMAIL list 10                             # recent inbox emails
$AMAIL list --unread                       # unread only
$AMAIL list --mailbox sent 5               # sent folder
$AMAIL read 79132                          # read email by ID
$AMAIL unread                              # unread count
$AMAIL thread-read 79132                   # full thread with bodies

# Searching
$AMAIL search "quarterly" --mailbox all 20 # search all mailboxes
$AMAIL search "report" --after 2026-03-01  # date range
$AMAIL search "alice" --from "@company"    # sender filter

# Composing
$AMAIL send --to user@example.com --subject "Hello" --body "Message"
$AMAIL send --to a@x.com --to b@x.com --subject "All" --body "Group message"
$AMAIL reply 79132 "Thanks!" --all
$AMAIL forward 79132 --to colleague@example.com

# Organization
$AMAIL flag 79132
$AMAIL move 79132 "Archive"
$AMAIL trash 79132

# Bulk operations (dry-run by default)
$AMAIL bulk-trash --mailbox "Newsletters" --force
$AMAIL bulk-move --mailbox "Old" --dest "Archive" --confirm

# Attachments & export
$AMAIL save-attachment 79132 --out ~/Downloads/
$AMAIL export 79132 --out ~/exported-email.md

# Watch / monitor
$AMAIL watch start                         # background monitoring
$AMAIL watch status                        # check if running
$AMAIL watch vip-add "boss@company.com"    # add VIP sender

# Info
$AMAIL accounts
$AMAIL folders
```

## Mailbox Names

- **System:** `inbox` (default), `sent`, `drafts`, `trash`, `junk`
- **Custom:** Exact folder name from `folders` output, e.g., `"Archive"`, `"Work/Projects"`

## Bulk Operation Safety

| Mode | Flag | Behavior |
|------|------|----------|
| Dry-run | (none) | Shows what would happen, no changes |
| Interactive | `--confirm` | Prompts y/N before each action |
| Automation | `--force` | Executes immediately, no prompt |

## Known Limitations

1. **Plain text only** — HTML stripped with notice
2. **Search** — Without `--body`, matches subject + sender only (fast)
3. **Bulk ops** — Require `--mailbox` flag
4. **Watch** — Requires Mail.app running
5. **Hierarchical mailboxes** — Up to 4 levels deep
