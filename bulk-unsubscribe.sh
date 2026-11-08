#!/usr/bin/env bash
# bulk-unsubscribe.sh — Bulk unsubscribe from mailing lists in one mailbox.
#
# Reads List-Unsubscribe / List-Unsubscribe-Post via Mail.app, then:
#   * RFC 8058 one-click: POST List-Unsubscribe=One-Click to the https URI
#     when the message advertises List-Unsubscribe-Post. Success is 200/202.
#     Redirects are not followed and are not success.
#   * RFC 2369 mailto: only when the message has no http(s) URI.
#   * Anything else is reported and not requested.
#
# --dry-run prints the plan only: no HTTP, no mail, no trash, no log file.
# --trash-after deletes inside the named account (see trash_in_account).
#
# Usage: bulk-unsubscribe.sh --help
#
# Bash 3.2+ (macOS). This file is safe to source: functions load, main does not run.

# ASCII Unit Separator. Subjects and header values are sanitized so they
# cannot contain this byte or a newline; tabs are not used as delimiters.
RECORD_SEP=$'\037'

# Escape a string for an AppleScript double-quoted literal.
# Same rule as apple-mail.sh osa_str: backslash, then double quote.
# CR/LF/TAB become spaces so a name cannot break the generated line.
osa_str() {
  local s
  s=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//$'\t'/ }
  printf '%s' "$s"
}

# Mailbox names may be hierarchical (Clients/Acme). The log file is a single
# path component, so replace characters that are unsafe in a filename.
# Letters outside ASCII are kept; empty or dot-only results become "mailbox".
safe_log_component() {
  local s
  # Allowlist, not a denylist: slash would end a sed s/// expression, and a
  # missed metacharacter would put another path component in the log name.
  # Bytes 128-255 stay so non-ASCII mailbox names are not destroyed.
  s=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._+\200-\377-' '_')
  if [[ -z "$s" || "$s" == "." || "$s" == ".." ]]; then
    s="mailbox"
  fi
  if [[ ${#s} -gt 80 ]]; then
    s=${s:0:80}
  fi
  printf '%s' "$s"
}

# Drop subscriber tokens before anything is written to disk or the terminal.
# Query strings and fragments are replaced. user:pass@ in http(s) URLs is removed.
# The path is kept so the log still shows which endpoint was used.
redact_target() {
  local url="$1" nofrag base scheme rest pathpart
  nofrag=${url%%#*}
  base=${nofrag%%\?*}
  if [[ "$base" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/]*)(.*)$ ]]; then
    scheme="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    pathpart="${BASH_REMATCH[3]}"
    rest="${rest#*@}"
    base="${scheme}${rest}${pathpart}"
  fi
  if [[ "$url" == *"?"* || "$url" == *"#"* ]]; then
    printf '%s?REDACTED' "$base"
  else
    printf '%s' "$base"
  fi
}

# --limit must be a base-10 integer. AppleScript treats leading-zero
# literals as octal ("08" is a syntax error), so callers embed the
# canonical value this function stores in LIMIT.
validate_limit() {
  local raw="$1"
  if [[ ! "$raw" =~ ^[0-9]+$ ]] || [[ ${#raw} -gt 9 ]]; then
    echo "Error: --limit requires an integer from 0 to 999999999" >&2
    return 1
  fi
  LIMIT=$((10#$raw))
  return 0
}

# True only for RFC 8058 success. 3xx is not success (no redirect following).
http_status_ok() {
  case "$1" in
    200|202) return 0 ;;
    *) return 1 ;;
  esac
}

# Decide how to unsubscribe. Prints "METHOD${RECORD_SEP}TARGET".
# METHOD is POST, MAILTO, NOT_ONECLICK, or NO_PARSE.
#
# POST is only the RFC 8058 one-click request: an https URI plus
# List-Unsubscribe-Post: List-Unsubscribe=One-Click.
# An http(s) URI without that signal is NOT_ONECLICK — we do not GET it
# (a followed redirect to a confirmation page used to look like success)
# and we do not switch to mailto, because a message that has an http(s)
# link never took the mailto path before. mailto is only used when the
# header has no http(s) URI at all.
decide_unsub() {
  local header="$1" post="$2"
  local clean https http_url mailto postclean
  clean=$(printf '%s' "$header" | LC_ALL=C tr -d ' \t\r\n')
  https=$(printf '%s\n' "$clean" | grep -oEi 'https://[^>",[:space:]]+' || true)
  http_url=$(printf '%s\n' "$clean" | grep -oEi 'http://[^>",[:space:]]+' || true)
  mailto=$(printf '%s\n' "$clean" | grep -oEi 'mailto:[^>",[:space:]]+' || true)
  https=${https%%$'\n'*}
  http_url=${http_url%%$'\n'*}
  mailto=${mailto%%$'\n'*}
  postclean=$(printf '%s' "$post" | LC_ALL=C tr -d ' \t\r\n' | LC_ALL=C tr '[:upper:]' '[:lower:]')
  if [[ -n "$https" && "$postclean" == *"list-unsubscribe=one-click"* ]]; then
    printf 'POST%s%s\n' "$RECORD_SEP" "$https"
    return 0
  fi
  if [[ -n "$https" || -n "$http_url" ]]; then
    printf 'NOT_ONECLICK%s%s\n' "$RECORD_SEP" "$mailto"
    return 0
  fi
  if [[ -n "$mailto" ]]; then
    printf 'MAILTO%s%s\n' "$RECORD_SEP" "$mailto"
    return 0
  fi
  printf 'NO_PARSE%s\n' "$RECORD_SEP"
  return 0
}

# AppleScript helpers live outside `tell application "Mail"`.
# Defining a handler inside that tell is illegal; calling one with `my` is not.
applescript_field_helpers() {
  cat << 'APPLESCRIPT'
on toLower(s)
  set upperChars to "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  set lowerChars to "abcdefghijklmnopqrstuvwxyz"
  set t to s as string
  set out to ""
  considering case
    repeat with ch in characters of t
      set chs to ch as string
      set idx to offset of chs in upperChars
      if idx > 0 then
        set out to out & character idx of lowerChars
      else
        set out to out & chs
      end if
    end repeat
  end considering
  return out
end toLower

on startsWithHeader(ln, headerLower)
  set prefixLen to length of headerLower
  set t to ln as string
  if (count of t) < prefixLen then return false
  set prefix to text 1 thru prefixLen of t
  if my toLower(prefix) is headerLower then return true
  return false
end startsWithHeader

-- Newlines, CR, tab, and the record/field separators would split the TSV
-- the shell reads back. Replace them before the record is assembled.
on sanitizeField(rawText)
  set t to ""
  try
    set t to rawText as string
  on error
    return ""
  end try
  set oldDelims to AppleScript's text item delimiters
  set badList to {linefeed, return, tab, character id 31, character id 30}
  repeat with badChar in badList
    set AppleScript's text item delimiters to (contents of badChar)
    set parts to text items of t
    set AppleScript's text item delimiters to " "
    set t to parts as text
  end repeat
  set AppleScript's text item delimiters to oldDelims
  return t
end sanitizeField

on emitRecord(mid, subj, status, unsub, extra)
  set sep to character id 31
  return (sanitizeField(mid)) & sep & (sanitizeField(subj)) & sep & (sanitizeField(status)) & sep & (sanitizeField(unsub)) & sep & (sanitizeField(extra)) & linefeed
end emitRecord
APPLESCRIPT
}

usage() {
  cat << 'EOF'
bulk-unsubscribe.sh — Unsubscribe from mailing lists in one Apple Mail mailbox.

Usage:
  bulk-unsubscribe.sh [--mailbox <name>] [--account <name>] [--limit <n>]
                      [--dry-run] [--trash-after]
  bulk-unsubscribe.sh --help

Options:
  --mailbox <name>   Mailbox to process (default: zzUnsubscribe)
  --account <name>   Mail account name (default: iCloud)
  --limit <n>        Process at most n messages; 0 means all (default: 0)
  --dry-run          Show the plan only. Sends nothing, deletes nothing,
                     and does not create a log directory or file.
  --trash-after      After a successful unsubscribe, delete that message
                     from this account's mailbox. Ignored with --dry-run.
                     Delete is done by this script (account-scoped), not by
                     apple-mail.sh trash.
  --help, -h         Show this help and exit

HTTP unsubscribe is RFC 8058 one-click: POST body
"List-Unsubscribe=One-Click" to the https URI, and only when the message
has List-Unsubscribe-Post: List-Unsubscribe=One-Click.
HTTP 200 and 202 are success. Redirects are not followed; 3xx is failure.
mailto is used only when the List-Unsubscribe header has no http(s) URI.
Other http(s) links are reported as NOT_ONECLICK and are not requested.

Real runs log under ${UNSUBSCRIBE_LOG_DIR:-~/.apple-mail-cli/logs}.
The directory is mode 0700 and the file is mode 0600. Query strings,
fragments, and URL userinfo are redacted.
EOF
}

# Missing option values must not evaluate $2 under `set -u`.
parse_args() {
  MAILBOX="zzUnsubscribe"
  ACCOUNT="iCloud"
  DRY_RUN=false
  TRASH_AFTER=false
  LIMIT=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --mailbox|--account|--limit)
        if [[ $# -lt 2 ]]; then
          echo "Error: $1 requires a value" >&2
          usage >&2
          exit 1
        fi
        if [[ -z "$2" ]]; then
          echo "Error: $1 requires a value" >&2
          usage >&2
          exit 1
        fi
        case "$1" in
          --mailbox) MAILBOX="$2" ;;
          --account) ACCOUNT="$2" ;;
          --limit) LIMIT="$2" ;;
        esac
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --trash-after)
        TRASH_AFTER=true
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

init_paths() {
  APPLE_MAIL_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apple-mail.sh"
}

log_line() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    return 0
  fi
  if [[ -z "${LOG_FILE:-}" ]]; then
    return 0
  fi
  local line="$1"
  line=${line//$'\n'/ }
  line=${line//$'\r'/ }
  printf '%s\n' "$line" >> "$LOG_FILE" || true
}

setup_log() {
  local dir safe_mb
  umask 077
  dir="${UNSUBSCRIBE_LOG_DIR:-$HOME/.apple-mail-cli/logs}"
  if ! mkdir -p -- "$dir"; then
    echo "ERROR: cannot create log directory: $dir" >&2
    exit 1
  fi
  # macOS chmod has no -- end-of-options marker; the path is absolute or under $HOME.
  if ! chmod 700 "$dir"; then
    echo "ERROR: cannot set mode 0700 on log directory: $dir" >&2
    exit 1
  fi
  safe_mb=$(safe_log_component "$MAILBOX")
  # safe_mb is a single path component; slashes in the mailbox name are gone.
  LOG_FILE="${dir}/Unsubscribe Log $(date +%Y-%m-%d_%H:%M) - ${safe_mb}.log"
  if ! : > "$LOG_FILE"; then
    echo "ERROR: cannot create log file: $LOG_FILE" >&2
    exit 1
  fi
  chmod 600 "$LOG_FILE" || {
    echo "ERROR: cannot set mode 0600 on log file: $LOG_FILE" >&2
    exit 1
  }
  printf '%s\n' "# Bulk Unsubscribe Log — $(date)" >> "$LOG_FILE"
  printf '%s\n' "# Mailbox: $ACCOUNT / $MAILBOX" >> "$LOG_FILE"
  printf '%s\n' "# Dry run: false" >> "$LOG_FILE"
  printf '%s\n' "# URL query strings, fragments, and userinfo are redacted." >> "$LOG_FILE"
  printf '\n' >> "$LOG_FILE"
  echo "Log: $LOG_FILE" >&2
}

# One osascript for the whole mailbox. Account lookup and mailbox lookup are
# separate tries so a bad --account is not reported as a missing mailbox.
# Each message has its own try: one unreadable message becomes a READ_FAIL
# record and the rest are still returned. A non-zero osascript status is
# caught by the caller; `set -e` must not skip that check.
fetch_headers() {
  local esc_acct esc_mb rc
  esc_acct=$(osa_str "$ACCOUNT")
  esc_mb=$(osa_str "$MAILBOX")
  if [[ ! "$LIMIT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: internal limit check failed" >&2
    exit 1
  fi
  rc=0
  HEADERS_TSV=$(osascript << APPLESCRIPT
$(applescript_field_helpers)
tell application "Mail"
  try
    set acct_ to account "$esc_acct"
  on error
    return "ERROR: Account not found: $esc_acct"
  end try
  try
    set mb_ to first mailbox of acct_ whose name is "$esc_mb"
  on error
    return "ERROR: Mailbox not found in account: $esc_mb"
  end try
  set output to ""
  set msgCount to count of (messages of mb_)
  set maxCount to $LIMIT
  if maxCount = 0 or maxCount > msgCount then set maxCount to msgCount
  repeat with i from 1 to maxCount
    set mid to ""
    set subj to ""
    set unsubLine to ""
    set unsubPost to ""
    set capture to ""
    try
      set msg_ to message i of mb_
      set mid to id of msg_ as string
      try
        set subj to subject of msg_ as string
      end try
      set hdrs to («class alhe» of msg_) as string
      set hdrLines to paragraphs of hdrs
      repeat with ln_ in hdrLines
        set lnStr to ln_ as string
        if my startsWithHeader(lnStr, "list-unsubscribe-post:") then
          if unsubPost is "" then
            set unsubPost to lnStr
            set capture to "post"
          else
            set capture to ""
          end if
        else if my startsWithHeader(lnStr, "list-unsubscribe:") then
          if unsubLine is "" then
            set unsubLine to lnStr
            set capture to "unsub"
          else
            set capture to ""
          end if
        else if capture is "post" and (lnStr starts with " " or lnStr starts with tab) then
          set unsubPost to unsubPost & lnStr
        else if capture is "unsub" and (lnStr starts with " " or lnStr starts with tab) then
          set unsubLine to unsubLine & lnStr
        else
          set capture to ""
        end if
      end repeat
      if unsubLine is "" then
        set output to output & my emitRecord(mid, subj, "NO_HEADER", "", "")
      else
        set output to output & my emitRecord(mid, subj, "OK", unsubLine, unsubPost)
      end if
    on error errMsg
      set output to output & my emitRecord(mid, subj, "READ_FAIL", "", errMsg)
    end try
  end repeat
  return output
end tell
APPLESCRIPT
) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR: failed to read mailbox headers (osascript exit $rc)" >&2
    exit 1
  fi
  if [[ "$HEADERS_TSV" == ERROR:* ]]; then
    printf '%s\n' "$HEADERS_TSV" >&2
    exit 1
  fi
}

# --trash-after deletes here instead of `apple-mail.sh trash`.
#
# apple-mail.sh trash only accepts --mailbox. Its mb_resolve walks every
# account and keeps the first mailbox of that name, so the account we just
# read is dropped. A same-named mailbox in another account can then supply
# a colliding message id and the wrong message is deleted. This script
# already required --account (default iCloud); the delete uses that same
# account and mailbox. A future CLI --account flag is intentionally not
# required.
trash_in_account() {
  local mid="$1" esc_acct esc_mb result rc
  if [[ ! "$mid" =~ ^[0-9]+$ ]]; then
    printf '%s' "ERROR: message id is not numeric"
    return 1
  fi
  esc_acct=$(osa_str "$ACCOUNT")
  esc_mb=$(osa_str "$MAILBOX")
  rc=0
  result=$(osascript << APPLESCRIPT
tell application "Mail"
  try
    set acct_ to account "$esc_acct"
  on error
    return "ERROR: Account not found"
  end try
  try
    set mb_ to first mailbox of acct_ whose name is "$esc_mb"
  on error
    return "ERROR: Mailbox not found in account"
  end try
  set wanted to "$mid"
  set targetMessage to missing value
  try
    set targetMessage to first message of mb_ whose id is (wanted as integer)
  end try
  if targetMessage is missing value then
    repeat with msg_ in messages of mb_
      try
        if (id of msg_ as string) is wanted then
          set targetMessage to msg_
          exit repeat
        end if
      end try
    end repeat
  end if
  if targetMessage is missing value then
    return "ERROR: Message not found in this account mailbox"
  end if
  try
    delete targetMessage
    return "OK"
  on error errMsg
    return "ERROR: " & errMsg
  end try
end tell
APPLESCRIPT
) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s' "ERROR: osascript exit $rc"
    return 1
  fi
  result=${result//$'\n'/ }
  result=${result//$'\r'/ }
  printf '%s' "$result"
  [[ "$result" == "OK" ]]
}

maybe_trash() {
  local mid="$1" subject="$2" trash_result
  if [[ "$TRASH_AFTER" != "true" ]]; then
    return 0
  fi
  trash_result=$(trash_in_account "$mid" || true)
  if [[ "$trash_result" == "OK" ]]; then
    return 0
  fi
  TRASH_FAIL=$((TRASH_FAIL + 1))
  echo "⚠️  TRASH_FAIL | $subject | ${trash_result:-delete failed}"
  log_line "TRASH_FAIL | $mid | $subject | ${trash_result:-delete failed}"
  return 0
}

do_http_post() {
  local raw="$1" subject="$2" redacted status
  redacted=$(redact_target "$raw")
  # No -L / --location: a 301 or 302 must stay a failure, not become the
  # confirmation page's 200. --max-redirs 0 keeps that even if -L is added later.
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --proto '=https' \
    --max-redirs 0 \
    --max-time 15 \
    --user-agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-binary "List-Unsubscribe=One-Click" \
    -- "$raw") || status="000"
  status=${status//$'\r'/}
  status=${status//$'\n'/}
  if http_status_ok "$status"; then
    echo "✅ UNSUB_OK | POST $status | $subject"
    log_line "SUCCESS | $MSG_ID | POST $status | $redacted | $subject"
    SUCCESS=$((SUCCESS + 1))
    maybe_trash "$MSG_ID" "$subject"
  else
    echo "❌ UNSUB_FAIL | POST $status | $subject"
    log_line "FAILED | $MSG_ID | POST $status | $redacted | $subject"
    FAILED=$((FAILED + 1))
  fi
  sleep 0.5 || true
  return 0
}

do_mailto() {
  local raw="$1" subject="$2"
  local addr subj decoded redacted
  addr=${raw#mailto:}
  addr=${addr%%\?*}
  if [[ -z "$addr" || "$addr" == *" "* || "$addr" == *$'\n'* ]]; then
    echo "⚠️  NO_PARSE | $subject"
    log_line "NO_PARSE | $MSG_ID | $subject"
    NO_PARSE=$((NO_PARSE + 1))
    return 0
  fi
  subj=$(printf '%s\n' "$raw" | grep -oE 'subject=[^&]+' || true)
  subj=${subj%%$'\n'*}
  subj=${subj#subject=}
  if [[ -n "$subj" ]]; then
    decoded=$(printf '%s' "$subj" | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || true)
    if [[ -n "$decoded" ]]; then
      subj=$decoded
    fi
  fi
  if [[ -z "$subj" ]]; then
    subj="unsubscribe"
  fi
  redacted=$(redact_target "$raw")
  if bash "$APPLE_MAIL_SH" send \
    --to "$addr" \
    --subject "$subj" \
    --body "Please unsubscribe me from this mailing list."
  then
    echo "✅ UNSUB_OK | MAILTO | $subject"
    log_line "SUCCESS | $MSG_ID | MAILTO | $redacted | $subject"
    SUCCESS=$((SUCCESS + 1))
    maybe_trash "$MSG_ID" "$subject"
  else
    echo "❌ UNSUB_FAIL | MAILTO | $subject"
    log_line "FAILED | $MSG_ID | MAILTO | $redacted | $subject"
    FAILED=$((FAILED + 1))
  fi
  sleep 0.5 || true
  return 0
}

process_message() {
  MSG_ID="$1"
  local subject="$2" status="$3" unsub_header="$4" unsub_extra="$5"
  local decision method target redacted

  case "$status" in
    NO_HEADER)
      echo "⚠️  NO_HEADER | $subject"
      log_line "NO_HEADER | $MSG_ID | $subject"
      NO_HEADER=$((NO_HEADER + 1))
      return 0
      ;;
    READ_FAIL)
      echo "⚠️  READ_FAIL | $subject | $unsub_extra"
      log_line "READ_FAIL | $MSG_ID | $subject | $unsub_extra"
      READ_FAIL=$((READ_FAIL + 1))
      return 0
      ;;
    OK)
      ;;
    *)
      echo "⚠️  READ_FAIL | $subject | unknown record status"
      log_line "READ_FAIL | $MSG_ID | $subject | unknown status $status"
      READ_FAIL=$((READ_FAIL + 1))
      return 0
      ;;
  esac

  decision=$(decide_unsub "$unsub_header" "$unsub_extra" || printf 'NO_PARSE%s\n' "$RECORD_SEP")
  IFS=$RECORD_SEP read -r method target << EOF || true
$decision
EOF

  case "$method" in
    NOT_ONECLICK)
      echo "⚠️  NOT_ONECLICK | $subject"
      if [[ -n "$target" ]]; then
        redacted=$(redact_target "$target")
        log_line "NOT_ONECLICK | $MSG_ID | $subject | mailto-present $redacted"
      else
        log_line "NOT_ONECLICK | $MSG_ID | $subject"
      fi
      NOT_ONECLICK=$((NOT_ONECLICK + 1))
      return 0
      ;;
    NO_PARSE|"")
      echo "⚠️  NO_PARSE | $subject"
      log_line "NO_PARSE | $MSG_ID | $subject"
      NO_PARSE=$((NO_PARSE + 1))
      return 0
      ;;
    POST|MAILTO)
      ;;
    *)
      echo "⚠️  NO_PARSE | $subject"
      log_line "NO_PARSE | $MSG_ID | $subject"
      NO_PARSE=$((NO_PARSE + 1))
      return 0
      ;;
  esac

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "🔍 DRY_RUN | $method | $subject"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if [[ "$method" == "POST" ]]; then
    do_http_post "$target" "$subject"
  else
    do_mailto "$target" "$subject"
  fi
  return 0
}

# One bad shell-side record must not abort the rest. AppleScript already
# turned unreadable messages into READ_FAIL rows; this covers curl/send/trash.
process_headers() {
  local local_rc
  while IFS=$RECORD_SEP read -r MSG_ID SUBJECT STATUS UNSUB_HEADER UNSUB_EXTRA || [[ -n "${MSG_ID:-}${STATUS:-}" ]]; do
    if [[ -z "${MSG_ID:-}" && -z "${STATUS:-}" ]]; then
      continue
    fi
    TOTAL=$((TOTAL + 1))
    set +e
    process_message "$MSG_ID" "$SUBJECT" "$STATUS" "$UNSUB_HEADER" "$UNSUB_EXTRA"
    local_rc=$?
    set -e
    if [[ "$local_rc" -ne 0 ]]; then
      FAILED=$((FAILED + 1))
      echo "❌ MESSAGE_FAIL | ${SUBJECT:-unknown}" >&2
      log_line "FAILED | ${MSG_ID:-} | ${SUBJECT:-} | message handler aborted"
    fi
  done <<< "$HEADERS_TSV"
}

main() {
  set -euo pipefail

  parse_args "$@"
  validate_limit "$LIMIT" || exit 1
  init_paths

  echo "=== Bulk Unsubscribe: $ACCOUNT / $MAILBOX ===" >&2
  echo "Dry run: $DRY_RUN | Trash after: $TRASH_AFTER | Limit: $LIMIT" >&2
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run: no unsubscribe requests, no deletes, no log file." >&2
  fi

  echo "Fetching email headers from mailbox..." >&2
  fetch_headers

  if [[ "$DRY_RUN" == "true" ]]; then
    LOG_FILE=""
  else
    setup_log
  fi

  TOTAL=0
  SUCCESS=0
  FAILED=0
  NO_HEADER=0
  NO_PARSE=0
  NOT_ONECLICK=0
  READ_FAIL=0
  TRASH_FAIL=0
  SKIPPED=0
  process_headers

  echo "" >&2
  echo "=== Results ===" >&2
  echo "Total:         $TOTAL" >&2
  echo "✅ Succeeded:  $SUCCESS" >&2
  echo "❌ Failed:     $FAILED" >&2
  echo "⚠️  No header:  $NO_HEADER" >&2
  echo "⚠️  Unparsed:   $NO_PARSE" >&2
  echo "⚠️  Not one-click: $NOT_ONECLICK" >&2
  echo "⚠️  Read errors: $READ_FAIL" >&2
  echo "⚠️  Trash failed: $TRASH_FAIL" >&2
  echo "🔍 Skipped:    $SKIPPED" >&2
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Log: (not written; dry-run)" >&2
  else
    echo "Log: $LOG_FILE" >&2
  fi

  echo ""
  echo "Total=$TOTAL Success=$SUCCESS Failed=$FAILED NoHeader=$NO_HEADER NoParse=$NO_PARSE NotOneClick=$NOT_ONECLICK ReadFail=$READ_FAIL TrashFail=$TRASH_FAIL Skipped=$SKIPPED"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
