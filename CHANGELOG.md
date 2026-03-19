# Changelog

All notable changes to Apple Mail CLI are documented here.

## v2.3.0 — 2026-03-12

**Watch / Monitor System**

- Added `watch start` — background monitoring via launchd (every 2 min)
- Added `watch stop` / `watch status` — service lifecycle management
- Added `watch check` — manual one-time check
- Added `watch log [N]` — view recent notification log
- Added `watch vip` / `watch vip-add` — VIP sender management
- VIP senders get individual macOS notifications with sound
- Regular mail gets batch summary notifications
- Optional voice notification support via TTS server
- **33 commands total**

## v2.2.0 — 2026-02-27

**Bulk Operations & Advanced Search**

- Added `bulk-trash`, `bulk-move`, `bulk-mark-read` with three safety modes (dry-run, `--confirm`, `--force`)
- Added date-range search: `--after` and `--before` flags
- Added `--unread` filter for list and search commands
- Added multi-recipient `--to` flag (repeatable) for send
- Added HTML content detection with strip notice
- Added smoke test suite (`test-apple-mail.sh`)
- Added `bulk-unsubscribe.sh` — RFC 8058 one-click unsubscribe tool
- **26 commands total**

## v2.1.0 — 2026-02-27

**Attachments & Export**

- Added `save-attachment` — download attachments to disk
- Added `export` — export email to Markdown with YAML frontmatter
- Added `archive` — move to Archive mailbox
- Added `thread-read` — full thread with message bodies, chronological
- Added CC/BCC support for `reply` and `reply-all`
- **24 commands total**

## v2.0.0 — 2026-02-27

**Initial Release**

Full-featured macOS Mail.app CLI with 19 commands:

- **Reading:** `list`, `read`, `unread`, `thread`, `attachments`
- **Searching:** `search` with subject, sender, body, and mailbox filters
- **Composing:** `send` (with attachments), `reply`, `reply-all`, `forward`, `draft`
- **Organization:** `flag`, `unflag`, `mark-read`, `mark-unread`, `move`, `trash`
- **Info:** `accounts`, `folders` (with unread/total counts)
- Custom mailbox support (50+ iCloud folders, hierarchical paths up to 4 levels)
- AppleScript string escaping and dynamic mailbox resolution
- Multi-account support with automatic account discovery
- **19 commands total**
