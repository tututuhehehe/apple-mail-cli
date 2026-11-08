#!/bin/bash
#
# Apple Mail Watch — New Mail Checker
# Called by Keyboard Maestro or launchd on a schedule.
# Compares current unread messages against last-known state.
# Notifies on new arrivals, with VIP priority alerting.
#
# State machine (do not regress):
#   * No state file: write this snapshot and exit without notifying.
#     That is the seed `apple-mail.sh watch start` promises.
#   * Fetch failed, empty, or not valid JSON: leave the state file
#     untouched and exit non-zero. Writing "[]" or an empty file here
#     makes the next run treat every unread message as new.
#   * State file exists but does not parse: rewrite it from the current
#     snapshot and do not notify. A failed parse must not look like
#     "nothing was unread".
#   * Otherwise: diff ids, atomically replace the snapshot, then notify.
#

CACHE_DIR="$HOME/.cache/apple-mail-watch"
STATE_FILE="$CACHE_DIR/last-check.json"
LOG_FILE="$CACHE_DIR/watch.log"
LOG_MAX_BYTES=1048576
LOCK_DIR="$CACHE_DIR/lock"
VIP_FILE="${APPLE_MAIL_VIP_FILE:-$(cd "$(dirname "$0")" && pwd)/watch-vip.txt}"
VIP_MIN_LEN=3
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_MAIL="$SCRIPT_DIR/apple-mail.sh"
# Newline-separated VIP patterns loaded once per notifying run.
VIP_PATTERNS=""
# Temp stderr from the Mail fetch; removed by the EXIT trap.
ERR_FILE=""

mkdir -p "$CACHE_DIR"

# Get current unread message IDs and metadata from inbox.
# Prints a JSON array to stdout. Exits non-zero (and prints nothing
# useful) when Mail is not running or AppleScript fails — callers must
# not persist that result.
get_unread_json() {
    osascript << 'OSAEOF'
-- BEGIN json builders
on jsonControl(code)
    set bs to character id 92
    if code is 9 then return bs & "t"
    if code is 10 then return bs & "n"
    if code is 13 then return bs & "r"
    set hex to "0123456789abcdef"
    set hi to character ((code div 16) + 1) of hex
    set lo to character ((code mod 16) + 1) of hex
    return bs & "u00" & hi & lo
end jsonControl

-- Escape one AppleScript string as a JSON string literal body.
-- Backslash first, then quote, then every other C0 control.
-- NUL (character id 0) is skipped: AppleScript text item delimiters
-- cannot hold it. Mail subjects do not contain NUL.
on jsonEscape(s)
    set tid to AppleScript's text item delimiters
    set bs to character id 92
    set qt to character id 34
    set AppleScript's text item delimiters to bs
    set parts to text items of s
    set AppleScript's text item delimiters to bs & bs
    set s to parts as string
    set AppleScript's text item delimiters to qt
    set parts to text items of s
    set AppleScript's text item delimiters to bs & qt
    set s to parts as string
    repeat with code from 1 to 31
        set AppleScript's text item delimiters to character id code
        set parts to text items of s
        if (count of parts) > 1 then
            set repl to my jsonControl(code)
            set AppleScript's text item delimiters to repl
            set s to parts as string
        end if
    end repeat
    set AppleScript's text item delimiters to tid
    return s
end jsonEscape

on jsonMessage(msgId, msgSender, msgSubject)
    set msgSender to my jsonEscape(msgSender)
    set msgSubject to my jsonEscape(msgSubject)
    return "{\"id\":" & msgId & ",\"sender\":\"" & msgSender & "\",\"subject\":\"" & msgSubject & "\"}"
end jsonMessage
-- END json builders

tell application "Mail"
    if not running then error "Mail is not running"
    set unreadMsgs to (messages of inbox whose read status is false)
    if (count of unreadMsgs) is 0 then return "[]"

    -- Do not truncate. A saved prefix is a permanently incomplete
    -- snapshot: any unread message left out is reported as new mail
    -- the moment it slides into the window. Keep every unread id.
    set savedTid to AppleScript's text item delimiters
    set objects to {}
    repeat with msg in unreadMsgs
        set msgId to ""
        set msgSender to ""
        set msgSubject to ""
        try
            set msgId to id of msg as string
        end try
        if msgId is not "" then
            try
                set msgSender to sender of msg as string
            end try
            try
                set msgSubject to subject of msg as string
            end try
            set end of objects to my jsonMessage(msgId, msgSender, msgSubject)
        end if
    end repeat
    -- Unread mail we could not identify is a failed read, not an empty
    -- inbox. Returning [] here would wipe the previous snapshot.
    if (count of objects) is 0 then error "unread messages had no readable ids"
    set AppleScript's text item delimiters to ","
    set jsonOut to "[" & (objects as string) & "]"
    set AppleScript's text item delimiters to savedTid
    return jsonOut
end tell
OSAEOF
}

# Print one id per line. Non-zero if stdin is not a list of {id: ...}.
parse_ids() {
    /usr/bin/python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, list):
    sys.exit(1)
for item in data:
    if not isinstance(item, dict) or "id" not in item:
        sys.exit(1)
    sys.stdout.write("%s\n" % item["id"])
'
}

# Read one field of one message from the current JSON payload.
json_field() {
    local id="$1" key="$2"
    printf '%s' "$current_json" | /usr/bin/python3 -c '
import json, sys
want = sys.argv[1]
key = sys.argv[2]
data = json.load(sys.stdin)
found = None
for item in data:
    if str(item.get("id")) == want:
        found = item.get(key, "")
        if found is None:
            found = ""
        break
if found is None:
    if key == "sender":
        found = "unknown"
    else:
        found = ""
sys.stdout.write(str(found))
' "$id" "$key"
}

# Normalize the VIP file into $VIP_PATTERNS (one pattern per line).
# Trim surrounding whitespace and CR, skip blanks and comments, and
# drop fragments shorter than VIP_MIN_LEN so "hr" cannot match "shred".
load_vip_patterns() {
    VIP_PATTERNS=""
    [[ -f "$VIP_FILE" ]] || return 0
    local line trimmed
    local patterns=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -z "$trimmed" || "$trimmed" == '#'* ]] && continue
        if [[ ${#trimmed} -lt $VIP_MIN_LEN ]]; then
            log_entry "VIP skip (shorter than ${VIP_MIN_LEN} characters): $trimmed"
            continue
        fi
        patterns+=("$trimmed")
    done < "$VIP_FILE"
    if [[ ${#patterns[@]} -gt 0 ]]; then
        VIP_PATTERNS=$(printf '%s\n' "${patterns[@]}")
    fi
}

# Check if a sender matches any loaded VIP pattern.
# Prints the matched pattern and returns 0, or returns 1.
is_vip() {
    local sender="$1"
    local sender_lower vip vip_lower
    sender_lower=$(printf '%s' "$sender" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    while IFS= read -r vip; do
        [[ -z "$vip" ]] && continue
        vip_lower=$(printf '%s' "$vip" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        if [[ "$sender_lower" == *"$vip_lower"* ]]; then
            printf '%s\n' "$vip"
            return 0
        fi
    done <<< "$VIP_PATTERNS"
    return 1
}

# Escape a value for an AppleScript double-quoted string.
# A raw " or \ is a syntax error, and osascript then drops the whole
# notification rather than truncating the text. Control characters are
# folded to spaces because AppleScript string literals cannot span lines.
osa_escape() {
    printf '%s' "$1" | LC_ALL=C tr '[:cntrl:]' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Send macOS notification
notify() {
    local title="$1" message="$2" sound="${3:-default}"
    local title_esc message_esc sound_esc
    title_esc=$(osa_escape "$title")
    message_esc=$(osa_escape "$message")
    sound_esc=$(osa_escape "$sound")
    osascript <<EOF
display notification "$message_esc" with title "$title_esc" sound name "$sound_esc"
EOF
}

# Send voice notification if VoiceServer is running
voice_notify() {
    local message="$1"
    curl -s -m 2 -X POST http://localhost:8888/notify \
        -H "Content-Type: application/json" \
        -d "{\"message\": \"$message\", \"voice_id\": \"${VOICE_NOTIFY_ID:-default}\"}" \
        >/dev/null 2>&1 || true
}

# One-line log text: control characters would split the log record.
log_field() {
    printf '%s' "$1" | LC_ALL=C tr '[:cntrl:]' ' '
}

# Rotate watch.log to watch.log.1 once it reaches 1MB. One generation only.
rotate_log_if_needed() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size=$(stat -f '%z' "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -ge $LOG_MAX_BYTES ]]; then
        mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    fi
}

# Log entry
log_entry() {
    rotate_log_if_needed
    local ts
    ts=$(date '+%Y-%m-%d_%H:%M:%S')
    printf '[%s] %s\n' "$ts" "$*" >> "$LOG_FILE"
}

# mkdir is atomic on the same directory, so the lock dir is the mutex.
# Steal it only when the recorded pid is dead. A live holder is left
# alone: taking the lock out from under it can let a stale snapshot
# overwrite a newer one.
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" || true
        return 0
    fi

    local i holder=""
    for i in 1 2 3 4 5; do
        if [[ -f "$LOCK_DIR/pid" ]]; then
            holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
            break
        fi
        sleep 0.2
    done

    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
        return 1
    fi

    local stale="$CACHE_DIR/lock.stale.$$"
    if mv "$LOCK_DIR" "$stale" 2>/dev/null; then
        rm -rf "$stale"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$LOCK_DIR/pid" || true
            log_entry "Removed stale lock (previous pid ${holder:-unknown} not running)"
            return 0
        fi
    fi
    return 1
}

release_lock() {
    [[ -f "$LOCK_DIR/pid" ]] || return 0
    local holder
    holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [[ "$holder" == "$$" ]]; then
        rm -rf "$LOCK_DIR"
    fi
}

cleanup() {
    release_lock
    if [[ -n "${ERR_FILE:-}" && -f "$ERR_FILE" ]]; then
        rm -f "$ERR_FILE"
    fi
}
trap cleanup EXIT

# Same-directory rename is atomic. Readers see the old file or the new
# one, never a prefix of the JSON.
write_state() {
    local json="$1" tmp
    tmp=$(mktemp "$CACHE_DIR/last-check.json.XXXXXX") || return 1
    if ! printf '%s\n' "$json" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

count_ids() {
    local n=0 line
    if [[ -z "$1" ]]; then
        printf '0\n'
        return 0
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
    done <<< "$1"
    printf '%s\n' "$n"
}

# Main check
main() {
    local current_json="" current_ids="" prev_ids="" rc=0
    local reason="" id sender subject vip_match
    local new_ids=() new_vip=() new_regular=()
    local holder=""

    if ! acquire_lock; then
        if [[ -f "$LOCK_DIR/pid" ]]; then
            holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        fi
        log_entry "Skip: another check is running${holder:+ (pid $holder)}"
        exit 0
    fi

    ERR_FILE=$(mktemp "$CACHE_DIR/fetch-err.XXXXXX") || {
        log_entry "Could not create a temp file; state not updated"
        exit 1
    }
    current_json=$(get_unread_json 2>"$ERR_FILE")
    rc=$?

    # Empty stdout and a non-zero osascript status are both failures.
    # `[]` (inbox really empty) is neither: it is valid and must be saved.
    local nonempty
    nonempty=$(printf '%s' "$current_json" | tr -d '[:space:]')
    if [[ $rc -ne 0 || -z "$nonempty" ]]; then
        reason=$(tr '\n' ' ' < "$ERR_FILE" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')
        reason=${reason:0:300}
        [[ -z "$reason" ]] && reason="empty output"
        log_entry "Fetch failed (rc=$rc): $reason; state not updated"
        exit 1
    fi
    rm -f "$ERR_FILE"
    ERR_FILE=""

    if ! current_ids=$(printf '%s' "$current_json" | parse_ids); then
        log_entry "Fetch returned invalid JSON; state not updated"
        exit 1
    fi

    # Record too-short VIP lines on every successful read, including
    # quiet polls, so a bad entry does not fail silently until new mail.
    load_vip_patterns

    # First run (or a wiped state file): record the baseline, stay quiet.
    if [[ ! -f "$STATE_FILE" ]]; then
        if ! write_state "$current_json"; then
            log_entry "Failed to seed state file; notifications suppressed"
            exit 1
        fi
        log_entry "Seeded initial state ($(count_ids "$current_ids") unread); notifications suppressed"
        exit 0
    fi

    if ! prev_ids=$(parse_ids < "$STATE_FILE"); then
        if ! write_state "$current_json"; then
            log_entry "State file unreadable and rewrite failed; notifications suppressed"
            exit 1
        fi
        log_entry "State file unreadable; re-seeded without notifying"
        exit 0
    fi

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if ! printf '%s\n' "$prev_ids" | grep -F -x -q -- "$id"; then
            new_ids+=("$id")
        fi
    done <<< "$current_ids"

    # Persist before notifying. A crash in Notification Center then
    # cannot re-report the same ids on the next run.
    if ! write_state "$current_json"; then
        log_entry "Failed to write state; notifications suppressed"
        exit 1
    fi

    if [[ ${#new_ids[@]} -eq 0 ]]; then
        exit 0
    fi

    for id in "${new_ids[@]}"; do
        sender=$(json_field "$id" sender 2>/dev/null || printf 'unknown')
        subject=$(json_field "$id" subject 2>/dev/null || printf '')

        if vip_match=$(is_vip "$sender"); then
            new_vip+=("$(log_field "$sender"): $(log_field "$subject")")
            log_entry "VIP: $(log_field "$sender") — $(log_field "$subject")"
        else
            new_regular+=("$(log_field "$sender"): $(log_field "$subject")")
            log_entry "NEW: $(log_field "$sender") — $(log_field "$subject")"
        fi
    done

    for msg in "${new_vip[@]}"; do
        if ! notify "📬 VIP Mail" "$msg" "Purr"; then
            log_entry "Notification failed (VIP)"
        fi
        voice_notify "New email from ${msg%%:*}"
    done

    local reg_count=${#new_regular[@]}
    if [[ $reg_count -gt 0 ]]; then
        if [[ $reg_count -eq 1 ]]; then
            if ! notify "📨 New Mail" "${new_regular[0]}" "default"; then
                log_entry "Notification failed"
            fi
        else
            local first_sender="${new_regular[0]%%:*}"
            if ! notify "📨 $reg_count New Emails" "From $first_sender and $((reg_count - 1)) others" "default"; then
                log_entry "Notification failed"
            fi
        fi
    fi

    local total=$((${#new_vip[@]} + ${#new_regular[@]}))
    log_entry "Check complete: $total new (${#new_vip[@]} VIP, ${#new_regular[@]} regular)"
}

main "$@"
