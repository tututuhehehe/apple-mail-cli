#!/usr/bin/env bash
# bulk-unsubscribe.sh — Bulk unsubscribe from emails in a mailbox
# Uses Apple Mail AppleScript to extract List-Unsubscribe headers,
# then sends HTTP GET or mailto unsubscribe requests.
#
# Usage:
#   bulk-unsubscribe.sh [--mailbox <name>] [--account <name>] [--dry-run] [--trash-after]
#
# Options:
#   --mailbox <name>   Mailbox to process (default: zzUnsubscribe)
#   --account <name>   iCloud account name (default: iCloud)
#   --dry-run          Show what would happen without actually unsubscribing
#   --trash-after      Move emails to trash after successful unsubscribe
#   --limit <n>        Process at most n emails (default: all)
#
# Output:
#   Prints one line per email: STATUS | SUBJECT | METHOD | URL

set -euo pipefail

MAILBOX="zzUnsubscribe"
ACCOUNT="iCloud"
DRY_RUN=false
TRASH_AFTER=false
LIMIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mailbox) MAILBOX="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --trash-after) TRASH_AFTER=true; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

APPLE_MAIL_SH="$(dirname "$0")/apple-mail.sh"

echo "=== Bulk Unsubscribe: $ACCOUNT / $MAILBOX ===" >&2
echo "Dry run: $DRY_RUN | Trash after: $TRASH_AFTER" >&2

# Step 1: Extract List-Unsubscribe headers for all messages in one AppleScript call
echo "Fetching email headers from mailbox..." >&2

HEADERS_TSV=$(osascript << APPLESCRIPT
tell application "Mail"
  try
    set mb_ to first mailbox of account "$ACCOUNT" whose name is "$MAILBOX"
  on error
    return "ERROR: Mailbox not found"
  end try
  set output to ""
  set msgCount to count of (messages of mb_)
  set maxCount to $LIMIT
  if maxCount = 0 then set maxCount to msgCount
  repeat with i from 1 to (maxCount)
    if i > msgCount then exit repeat
    set msg_ to message i of mb_
    set mid to id of msg_
    set subj to subject of msg_
    set hdrs to «class alhe» of msg_
    -- Extract List-Unsubscribe from headers
    set unsubLine to ""
    set prevChar to ""
    set inHeader to false
    set headerName to ""
    -- Simple line-by-line search for List-Unsubscribe
    set hdrLines to paragraphs of hdrs
    repeat with ln_ in hdrLines
      set lnStr to ln_ as string
      if lnStr starts with "List-Unsubscribe:" or lnStr starts with "list-unsubscribe:" then
        set unsubLine to lnStr
      else if unsubLine is not "" and (lnStr starts with " " or lnStr starts with tab) then
        -- Continuation line
        set unsubLine to unsubLine & lnStr
      else if unsubLine is not "" then
        exit repeat
      end if
    end repeat
    if unsubLine is not "" then
      set output to output & mid & tab & subj & tab & unsubLine & linefeed
    else
      set output to output & mid & tab & subj & tab & "NO_UNSUB" & linefeed
    end if
  end repeat
  return output
end tell
APPLESCRIPT
)

if [[ "$HEADERS_TSV" == "ERROR:"* ]]; then
  echo "$HEADERS_TSV" >&2
  exit 1
fi

# Step 2: Parse and process each email
TOTAL=0
SUCCESS=0
FAILED=0
NO_UNSUB=0
SKIPPED=0

# Log file
LOG_DIR="${UNSUBSCRIBE_LOG_DIR:-$HOME/.apple-mail-cli/logs}"
# Fall back to ~/.apple-mail-cli/logs/ if custom log dir not accessible
if [[ ! -d "$LOG_DIR" ]]; then
  LOG_DIR="$HOME/.apple-mail-cli/logs"
  mkdir -p "$LOG_DIR"
fi
LOG_FILE="${LOG_DIR}/Unsubscribe Log $(date +%Y-%m-%d_%H:%M) - ${MAILBOX}.log"
echo "Log: $LOG_FILE" >&2
echo "# Bulk Unsubscribe Log — $(date)" > "$LOG_FILE"
echo "# Mailbox: $ACCOUNT / $MAILBOX" >> "$LOG_FILE"
echo "# Dry run: $DRY_RUN" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

while IFS=$'\t' read -r MSG_ID SUBJECT UNSUB_HEADER; do
  [[ -z "$MSG_ID" ]] && continue
  TOTAL=$((TOTAL + 1))

  if [[ "$UNSUB_HEADER" == "NO_UNSUB" ]]; then
    echo "⚠️  NO_UNSUB | $SUBJECT"
    echo "NO_UNSUB | $MSG_ID | $SUBJECT" >> "$LOG_FILE"
    NO_UNSUB=$((NO_UNSUB + 1))
    continue
  fi

  # Extract HTTP URL and mailto from List-Unsubscribe header
  # Format: List-Unsubscribe: <https://...>, <mailto:...>
  # Strip RFC 2822 folding whitespace (space/tab inside URL tokens) before extracting
  CLEAN_HEADER=$(echo "$UNSUB_HEADER" | tr -d ' \t')
  HTTP_URL=$(echo "$CLEAN_HEADER" | grep -oE 'https?://[^>",]+' | head -1 || true)
  MAILTO=$(echo "$CLEAN_HEADER" | grep -oE 'mailto:[^>",]+' | head -1 || true)

  if [[ -n "$HTTP_URL" ]]; then
    METHOD="HTTP"
    TARGET="$HTTP_URL"
  elif [[ -n "$MAILTO" ]]; then
    METHOD="MAILTO"
    TARGET="$MAILTO"
  else
    echo "⚠️  NO_PARSE | $SUBJECT | $UNSUB_HEADER"
    echo "NO_PARSE | $MSG_ID | $SUBJECT | $UNSUB_HEADER" >> "$LOG_FILE"
    NO_UNSUB=$((NO_UNSUB + 1))
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "🔍 DRY_RUN  | $METHOD | $SUBJECT"
    echo "DRY_RUN | $MSG_ID | $METHOD | $TARGET | $SUBJECT" >> "$LOG_FILE"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Execute unsubscribe
  if [[ "$METHOD" == "HTTP" ]]; then
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -L \
      --max-time 15 \
      --user-agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
      "$HTTP_URL" 2>/dev/null || echo "000")

    if [[ "$STATUS_CODE" =~ ^(200|201|204|302|301)$ ]]; then
      echo "✅ UNSUB_OK | HTTP $STATUS_CODE | $SUBJECT"
      echo "SUCCESS | $MSG_ID | HTTP $STATUS_CODE | $TARGET | $SUBJECT" >> "$LOG_FILE"
      SUCCESS=$((SUCCESS + 1))

      if [[ "$TRASH_AFTER" == "true" ]]; then
        bash "$APPLE_MAIL_SH" trash "$MSG_ID" --mailbox "$MAILBOX" 2>/dev/null || true
      fi
    else
      echo "❌ UNSUB_FAIL | HTTP $STATUS_CODE | $SUBJECT"
      echo "FAILED | $MSG_ID | HTTP $STATUS_CODE | $TARGET | $SUBJECT" >> "$LOG_FILE"
      FAILED=$((FAILED + 1))
    fi

  elif [[ "$METHOD" == "MAILTO" ]]; then
    # Extract address from mailto:address?subject=...
    MAILTO_ADDR=$(echo "$MAILTO" | sed 's/mailto://;s/?.*//')
    MAILTO_SUBJ=$(echo "$MAILTO" | grep -oE 'subject=[^&]+' | head -1 | sed 's/subject=//' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "unsubscribe")

    bash "$APPLE_MAIL_SH" send \
      --to "$MAILTO_ADDR" \
      --subject "${MAILTO_SUBJ:-unsubscribe}" \
      --body "Please unsubscribe me from this mailing list." 2>/dev/null && {
      echo "✅ UNSUB_OK | MAILTO | $SUBJECT → $MAILTO_ADDR"
      echo "SUCCESS | $MSG_ID | MAILTO | $MAILTO_ADDR | $SUBJECT" >> "$LOG_FILE"
      SUCCESS=$((SUCCESS + 1))
      if [[ "$TRASH_AFTER" == "true" ]]; then
        bash "$APPLE_MAIL_SH" trash "$MSG_ID" --mailbox "$MAILBOX" 2>/dev/null || true
      fi
    } || {
      echo "❌ UNSUB_FAIL | MAILTO | $SUBJECT"
      echo "FAILED | $MSG_ID | MAILTO | $MAILTO_ADDR | $SUBJECT" >> "$LOG_FILE"
      FAILED=$((FAILED + 1))
    }
  fi

  # Small delay to avoid rate limiting
  sleep 0.5

done <<< "$HEADERS_TSV"

echo "" >&2
echo "=== Results ===" >&2
echo "Total:        $TOTAL" >&2
echo "✅ Succeeded: $SUCCESS" >&2
echo "❌ Failed:    $FAILED" >&2
echo "⚠️  No header: $NO_UNSUB" >&2
echo "🔍 Skipped:   $SKIPPED" >&2
echo "Log: $LOG_FILE" >&2

echo ""
echo "Total=$TOTAL Success=$SUCCESS Failed=$FAILED NoHeader=$NO_UNSUB"
