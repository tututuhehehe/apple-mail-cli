#!/bin/bash
#
# apple-mail.sh — Comprehensive macOS Mail.app CLI via AppleScript
# https://github.com/macos-cli-tools/apple-mail-cli
#

VERSION="2.3.0"

# ── 统一失败语义 ────────────────────────────────────────────────
# 需要取值的选项统一守卫：缺值时立刻失败，而不是让 "$2" 取空、
# shift 越界后原地死循环（旧行为：静默挂死、无输出、无法诊断）。
need_val() {
    local flag="$1" remaining="$2"
    if [[ "$remaining" -lt 2 ]]; then
        printf 'Error: %s requires a value\n' "$flag" >&2
        exit 1
    fi
}

# 包一层 osascript：把 AppleScript 的 "行:列: execution error: 消息 (-NNN)"
# 清洗成一行可读错误，并原样保留退出码。所有命令因此共用同一套失败语义：
# 失败 → 非零退出 + 单行 stderr，而不是把错误当正常输出并以 0 退出。
osascript() {
    local tmp out rc
    tmp=$(mktemp -t apple-mail-cli) || return 1
    out=$(command osascript "$@" 2>"$tmp"); rc=$?
    if [[ -s "$tmp" ]]; then
        sed -E 's/^[0-9]+:[0-9]+: (execution|syntax) error: //; s/ \(-[0-9]+\)$//' "$tmp" >&2
    fi
    rm -f "$tmp"
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return $rc
}

# Escape a string for safe embedding in AppleScript double-quoted string literals
osa_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Generate AppleScript that sets 'targetMailbox' from a mailbox name string.
# For system mailboxes: direct reference. For custom: searches accounts at runtime.
mb_resolve() {
    local m="${1:-inbox}"
    local m_lower m_esc
    m_lower=$(echo "$m" | tr '[:upper:]' '[:lower:]')
    m_esc=$(osa_str "$m")

    case "$m_lower" in
        ""|inbox)
            printf '    set targetMailbox to inbox\n' ;;
        sent|"sent messages")
            printf '    set targetMailbox to sent mailbox\n' ;;
        drafts|draft)
            printf '    set targetMailbox to drafts mailbox\n' ;;
        trash|deleted|"deleted messages")
            printf '    set targetMailbox to trash mailbox\n' ;;
        junk|spam)
            printf '    set targetMailbox to junk mailbox\n' ;;
        *)
            printf '    set targetMailbox to inbox\n'
            printf '    set mbFound_ to false\n'
            if [[ "$m" == *"/"* ]]; then
                # Hierarchical path: navigate up to 4 levels deep
                IFS='/' read -ra PATH_PARTS <<< "$m"
                local num_parts="${#PATH_PARTS[@]}"
                printf '    repeat with acct_ in accounts\n'
                printf '        try\n'
                local esc0; esc0=$(osa_str "${PATH_PARTS[0]}")
                printf '            set mb0_ to first mailbox of acct_ whose name is "%s"\n' "$esc0"
                if [[ $num_parts -ge 2 ]]; then
                    local esc1; esc1=$(osa_str "${PATH_PARTS[1]}")
                    printf '            set mb1_ to first mailbox of mb0_ whose name is "%s"\n' "$esc1"
                fi
                if [[ $num_parts -ge 3 ]]; then
                    local esc2; esc2=$(osa_str "${PATH_PARTS[2]}")
                    printf '            set mb2_ to first mailbox of mb1_ whose name is "%s"\n' "$esc2"
                fi
                if [[ $num_parts -ge 4 ]]; then
                    local esc3; esc3=$(osa_str "${PATH_PARTS[3]}")
                    printf '            set mb3_ to first mailbox of mb2_ whose name is "%s"\n' "$esc3"
                fi
                # Point targetMailbox at deepest resolved level
                case $num_parts in
                    2) printf '            set targetMailbox to mb1_\n' ;;
                    3) printf '            set targetMailbox to mb2_\n' ;;
                    4) printf '            set targetMailbox to mb3_\n' ;;
                    *) printf '            set targetMailbox to mb0_\n' ;;
                esac
                printf '            set mbFound_ to true\n'
                printf '            exit repeat\n'
                printf '        end try\n'
                printf '    end repeat\n'
            else
                printf '    repeat with acct_ in accounts\n'
                printf '        try\n'
                printf '            set targetMailbox to first mailbox of acct_ whose name is "%s"\n' "$m_esc"
                printf '            set mbFound_ to true\n'
                printf '            exit repeat\n'
                printf '        end try\n'
                printf '    end repeat\n'
            fi
            printf '    if not mbFound_ then\n'
            printf '        error "Mailbox not found: %s. Run apple-mail.sh folders to see all mailboxes."\n' "$m_esc"
            printf '    end if\n' ;;
    esac
}

# Generate AppleScript that finds a message by ID in targetMailbox → targetMessage
find_msg() {
    local id="$1" mb_label="${2:-inbox}"
    local esc_id
    esc_id=$(osa_str "$id")
    printf '    set targetMessage to null\n'
    printf '    try\n'
    printf '        set targetMessage to first message of targetMailbox whose id is (%s as integer)\n' "$esc_id"
    printf '    on error\n'
    printf '        repeat with msg_ in messages of targetMailbox\n'
    printf '            if (id of msg_ as string) is "%s" then\n' "$esc_id"
    printf '                set targetMessage to msg_\n'
    printf '                exit repeat\n'
    printf '            end if\n'
    printf '        end repeat\n'
    printf '    end try\n'
    printf '    if targetMessage is null then error "Email ID %s not found in %s"\n' "$esc_id" "$(osa_str "$mb_label")"
}

show_usage() {
    printf 'Apple Mail CLI v%s — Comprehensive macOS Mail.app Interface\n\n' "$VERSION"
    cat << 'USAGEEOF'
READING:
    list    [--mailbox <name>] [--unread] [count]
    read    <id> [--mailbox <name>]
    unread  [--mailbox <name>]
    thread  <id> [--mailbox <name>]
    thread-read <id> [--mailbox <name>]   (full thread with bodies)
    attachments <id> [--mailbox <name>]

SEARCHING:
    search  <query> [--mailbox <name>|all] [--from <addr>] [--unread] [--body] [--after YYYY-MM-DD] [--before YYYY-MM-DD] [count]
            Default: searches subject+sender (fast). Add --body for full-text (slow).

COMPOSING:
    send    --to <addr> [--to <addr2> ...] [--cc <addr>] [--bcc <addr>] [--from <email>] --subject <s> --body <b> [--attach /path] [--attach /path2]
            OR short form: send <to> <subject> <body>
            Multiple --to flags supported for multi-recipient sending.
    reply   <id> <body> [--all] [--mailbox <name>] [--cc <addr>] [--bcc <addr>]
    reply-all <id> <body> [--mailbox <name>] [--cc <addr>] [--bcc <addr>]
    forward <id> --to <addr> [--body <prefix>] [--mailbox <name>]
    draft   --to <addr> [--cc <addr>] --subject <s> --body <b>

ORGANIZATION:
    flag    <id> [--mailbox <name>]
    unflag  <id> [--mailbox <name>]
    mark-read   <id> [--mailbox <name>]
    mark-unread <id> [--mailbox <name>]
    move    <id> <dest> [--mailbox <src>]
    trash   <id> [--mailbox <name>]
    archive <id> [--mailbox <name>]

BULK OPERATIONS:
    bulk-trash     --mailbox <name> [--unread-only] [--confirm] [--force]
    bulk-move      --mailbox <name> --dest <name> [--unread-only] [--confirm] [--force]
    bulk-mark-read --mailbox <name> [--confirm] [--force]
    Default: dry-run. --confirm: execute with y/N prompt. --force: execute immediately (no prompt, automation-safe).

NEW COMMANDS:
    save-attachment <id> [--mailbox X] [--out /path/to/dir]   (default: ~/Downloads/)
    export <id> [--mailbox X] [--out /path/to/file.md]         (Obsidian email archival format)

WATCH (new mail monitoring):
    watch start     Start monitoring for new mail (every 2 min via launchd)
    watch stop      Stop monitoring
    watch status    Show if running, last check time, new messages since last session
    watch log [N]   Show recent watch notifications (default: 30 lines)
    watch vip       Show the VIP sender list
    watch vip-add <fragment>   Add a sender (or name fragment) to the VIP list
    watch check     Run a one-time check now (manual trigger)

INFO:
    accounts
    folders     (shows unread counts)

MAILBOX NAMES:
    System: inbox, sent, drafts, trash, junk
    Custom: exact name from 'folders' output  e.g. "Archive", "Work Projects"

EXAMPLES:
    apple-mail.sh list --mailbox sent 10
    apple-mail.sh list --unread
    apple-mail.sh list --mailbox "Work Projects" 5
    apple-mail.sh read 79132 --mailbox sent
    apple-mail.sh search "Oregon" --mailbox all 10
    apple-mail.sh search "smith" --from "@lawfirm.com" --mailbox all
    apple-mail.sh search "contract" --after 2026-02-01 --mailbox all
    apple-mail.sh send --to "colleague@company.com" --subject "Report" --body "See attached" --attach ~/Downloads/report.pdf
    apple-mail.sh reply 79132 "Thanks!" --all
    apple-mail.sh reply 79132 "Thanks" --cc colleague@example.com
    apple-mail.sh forward 79132 --to "colleague@example.com" --body "FYI:"
    apple-mail.sh flag 79132
    apple-mail.sh mark-unread 79132
    apple-mail.sh move 79132 "Archive"
    apple-mail.sh archive 76244
    apple-mail.sh save-attachment 5923 --mailbox "Clients" --out ~/Downloads/
    apple-mail.sh bulk-trash --mailbox "Junk" --confirm
    apple-mail.sh bulk-move --mailbox "Newsletters" --dest "Archive" --confirm
    apple-mail.sh thread-read 79132
    apple-mail.sh export 79132 --out ~/Documents/email.md
    apple-mail.sh unread --mailbox "Receipts"
    apple-mail.sh thread 79132

USAGEEOF
}

# ─────────────────────────────────────────────
# LIST
# ─────────────────────────────────────────────
list_emails() {
    local mailbox_name="inbox" unread_only="false" count=10
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            --unread|-u)  unread_only="true"; shift ;;
            *)            count="$1"; shift ;;
        esac
    done

    local esc_mb
    esc_mb=$(osa_str "$mailbox_name")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")

    if $unread_only then
        set allMessages to (messages of targetMailbox whose read status is false)
    else
        set allMessages to messages of targetMailbox
    end if

    set totalMessages to count of allMessages
    if totalMessages = 0 then
        if $unread_only then
            return "No unread messages in: $esc_mb"
        else
            return "No messages in: $esc_mb"
        end if
    end if

    set limitCount to $count
    if limitCount > totalMessages then set limitCount to totalMessages
    set messageList to items 1 thru limitCount of allMessages

    set output to "Mailbox: $esc_mb (" & totalMessages & " total)" & linefeed
    set output to output & "======================================" & linefeed

    repeat with msg in messageList
        set msgId to id of msg as string
        set readStatus to "[ ]"
        if read status of msg then set readStatus to "[READ]"
        set flagMark to "   "
        try
            if flagged status of msg then set flagMark to "[⚑]"
        end try
        set attMark to "   "
        try
            if (count of mail attachments of msg) > 0 then set attMark to "[📎]"
        end try
        set msgAcct to ""
        try
            set msgAcct to name of (account of mailbox of msg)
        end try
        set output to output & "ID:" & msgId & " " & readStatus & " " & flagMark & " " & attMark & " | " & (date received of msg as string) & " | " & (sender of msg) & " | " & (subject of msg) & " | ACCT:" & msgAcct & linefeed
    end repeat

    return output
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# READ
# ─────────────────────────────────────────────
read_email() {
    local email_id="$1"; shift
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local esc_mb
    esc_mb=$(osa_str "$mailbox_name")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set msgSubject to subject of targetMessage
    set msgSender to sender of targetMessage
    set msgDate to date received of targetMessage
    set msgBody to content of targetMessage
    set msgFlagged to flagged status of targetMessage

    set toAddrs to ""
    try
        repeat with r in to recipients of targetMessage
            set toAddrs to toAddrs & (address of r) & "  "
        end repeat
    end try

    set ccAddrs to ""
    try
        repeat with r in cc recipients of targetMessage
            set ccAddrs to ccAddrs & (address of r) & "  "
        end repeat
    end try

    set attInfo to ""
    set isHtml to false
    try
        set attList to mail attachments of targetMessage
        if (count of attList) > 0 then
            set attInfo to linefeed & "Attachments (" & (count of attList) & "):" & linefeed
            repeat with att in attList
                set attName to name of att
                set attMime to ""
                try
                    set attMime to mime type of att
                end try
                if attMime contains "html" then set isHtml to true
                try
                    set attInfo to attInfo & "  - " & attName & " (" & (file size of att) & " bytes)" & linefeed
                on error
                    set attInfo to attInfo & "  - " & attName & linefeed
                end try
            end repeat
        end if
    end try

    -- Detect HTML in body (inline HTML email)
    if msgBody contains "<html" or msgBody contains "<HTML" or msgBody contains "<div" or msgBody contains "<p>" then
        set isHtml to true
    end if

    set read status of targetMessage to true

    set output to "======================================" & linefeed
    set output to output & "Subject: " & msgSubject & linefeed
    set output to output & "From:    " & msgSender & linefeed
    if toAddrs is not "" then set output to output & "To:      " & toAddrs & linefeed
    if ccAddrs is not "" then set output to output & "CC:      " & ccAddrs & linefeed
    set output to output & "Date:    " & (msgDate as string) & linefeed
    set output to output & "Mailbox: $esc_mb  |  Flagged: " & msgFlagged & "  |  ID: " & (id of targetMessage as string) & linefeed
    if isHtml then set output to output & "[HTML email — displayed as plain text, formatting stripped]" & linefeed
    if attInfo is not "" then set output to output & attInfo
    set output to output & "======================================" & linefeed & linefeed
    set output to output & msgBody

    return output
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# SEARCH
# ─────────────────────────────────────────────
search_emails() {
    local query="" mailbox_name="inbox" from_filter=""
    local unread_only="false" search_body="false" count=20 search_all="false"
    local after_date="" before_date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m)
                mailbox_name="$2"
                [[ "$2" == "all" ]] && search_all="true"
                shift 2 ;;
            all)   mailbox_name="all"; search_all="true"; shift ;;
            --from|-f)   need_val "$1" "$#"; from_filter="$2"; shift 2 ;;
            --unread|-u) unread_only="true"; shift ;;
            --body|-b)   search_body="true"; shift ;;
            --after)     need_val "$1" "$#"; after_date="$2"; shift 2 ;;
            --before)    need_val "$1" "$#"; before_date="$2"; shift 2 ;;
            *)
                if [[ -z "$query" ]]; then query="$1"
                elif [[ "$1" =~ ^[0-9]+$ ]]; then count="$1"
                fi
                shift ;;
        esac
    done

    local esc_query esc_from esc_mb
    esc_query=$(osa_str "$query")
    esc_from=$(osa_str "$from_filter")
    esc_mb=$(osa_str "$mailbox_name")

    # Build mailbox list snippet
    local mb_list_osa
    if [[ "$search_all" == "true" ]]; then
        mb_list_osa=$(cat << 'MBLIST'
    -- 只搜「活着的邮件」。不再把合并 inbox 与 sent 单独加入（它们与各账户的
    -- INBOX / Sent Messages 是同一批邮件，此前 --mailbox all 把每封列两遍），
    -- 也排除 Junk / Deleted Messages / Drafts。
    set mailboxesToSearch to {}
    repeat with acct_ in accounts
        try
            repeat with mb_ in mailboxes of acct_
                set mbName_ to name of mb_
                if mbName_ is not "Junk" and mbName_ is not "Deleted Messages" and mbName_ is not "Drafts" then
                    set end of mailboxesToSearch to mb_
                end if
            end repeat
        end try
    end repeat
MBLIST
)
    else
        mb_list_osa="$(mb_resolve "$mailbox_name")
    set mailboxesToSearch to {targetMailbox}"
    fi

    local date_filter_osa=""
    local ymd
    if [[ -n "$after_date" ]]; then
        ymd="${after_date//-/}"; ymd="${ymd//\//}"
        if [[ ! "$ymd" =~ ^[0-9]{8}$ ]]; then
            echo "Error: --after expects YYYY-MM-DD (got: $after_date)" >&2; return 1
        fi
        date_filter_osa+="    set afterYMD_ to $ymd"$'\n'
        date_filter_osa+="    set filterAfter_ to true"$'\n'
    else
        date_filter_osa+="    set filterAfter_ to false"$'\n'
    fi
    if [[ -n "$before_date" ]]; then
        ymd="${before_date//-/}"; ymd="${ymd//\//}"
        if [[ ! "$ymd" =~ ^[0-9]{8}$ ]]; then
            echo "Error: --before expects YYYY-MM-DD (got: $before_date)" >&2; return 1
        fi
        date_filter_osa+="    set beforeYMD_ to $ymd"$'\n'
        date_filter_osa+="    set filterBefore_ to true"$'\n'
    else
        date_filter_osa+="    set filterBefore_ to false"$'\n'
    fi

    osascript << OSAEOF
tell application "Mail"
    if not running then launch

$mb_list_osa

$date_filter_osa
    set searchResults to {}
    set seenIds to {}
    set maxResults to $count

    repeat with searchMailbox in mailboxesToSearch
        try
            set msgList to messages of searchMailbox
            if $unread_only then
                set msgList to (messages of searchMailbox whose read status is false)
            end if

            repeat with msg in msgList
                if (count of searchResults) >= maxResults then exit repeat

                set msgSubject to subject of msg as string
                set msgSender to sender of msg as string

                set matchesQuery to false
                if "$esc_query" is "" then
                    set matchesQuery to true
                else if msgSubject contains "$esc_query" then
                    set matchesQuery to true
                else if msgSender contains "$esc_query" then
                    set matchesQuery to true
                end if

                if not matchesQuery and $search_body then
                    try
                        if (content of msg as string) contains "$esc_query" then
                            set matchesQuery to true
                        end if
                    end try
                end if

                set matchesFrom to true
                if "$esc_from" is not "" then
                    if msgSender does not contain "$esc_from" then
                        set matchesFrom to false
                    end if
                end if

                set includeMsg_ to true
                -- 用 YYYYMMDD 整数比较，绕开 AppleScript 的 date "MM/DD/YYYY" 对
                -- 系统短日期顺序的依赖：在 zh_CN 下 02/01/2026 会被解析成
                -- 2007-07-19，导致 --after 恒不生效、--before 恒为空。
                set d_ to date received of msg
                set msgYMD_ to (year of d_ as integer) * 10000 + (((month of d_) as integer) * 100) + (day of d_ as integer)
                if filterAfter_ and msgYMD_ < afterYMD_ then set includeMsg_ to false
                if filterBefore_ and msgYMD_ > beforeYMD_ then set includeMsg_ to false
                if matchesQuery and matchesFrom and includeMsg_ then
                    -- 同一条邮件可能出现在多个邮箱对象里，按 id 去重
                    set msgId_ to id of msg
                    if seenIds does not contain msgId_ then
                        set end of seenIds to msgId_
                        set end of searchResults to msg
                    end if
                end if
            end repeat
        end try
        if (count of searchResults) >= maxResults then exit repeat
    end repeat

    if (count of searchResults) = 0 then
        return "No results for: \"$esc_query\""
    end if

    set scopeLabel to "$esc_mb"
    if $search_all then set scopeLabel to "all mailboxes"
    set output to "Search: \"$esc_query\" in " & scopeLabel & " — " & (count of searchResults) & " result(s)" & linefeed
    set output to output & "======================================" & linefeed

    repeat with msg in searchResults
        set readStatus to "[ ]"
        if read status of msg then set readStatus to "[READ]"
        set flagMark to "   "
        try
            if flagged status of msg then set flagMark to "[⚑]"
        end try
        set mbName_ to ""
        try
            set mbName_ to name of mailbox of msg
        end try
        set output to output & "ID:" & (id of msg as string) & " " & readStatus & " " & flagMark & " [" & mbName_ & "] " & (date received of msg as string) & " | " & (sender of msg) & " | " & (subject of msg) & linefeed
    end repeat

    return output
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# SEND
# ─────────────────────────────────────────────
send_email() {
    local to_addrs=() cc_addr="" bcc_addr="" from_addr="" subject="" body=""
    local attachments=()

    if [[ $# -eq 3 ]] && [[ "$1" != --* ]]; then
        to_addrs=("$1"); subject="$2"; body="$3"
    else
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --to|-t)      need_val "$1" "$#"; to_addrs+=("$2"); shift 2 ;;
                --cc|-c)      need_val "$1" "$#"; cc_addr="$2"; shift 2 ;;
                --bcc|-b)     need_val "$1" "$#"; bcc_addr="$2"; shift 2 ;;
                --from|-f)    need_val "$1" "$#"; from_addr="$2"; shift 2 ;;
                --subject|-s) need_val "$1" "$#"; subject="$2"; shift 2 ;;
                --body|-B)    need_val "$1" "$#"; body="$2"; shift 2 ;;
                --attach|--attachment|-A)  need_val "$1" "$#"; attachments+=("$2"); shift 2 ;;
                *) shift ;;
            esac
        done
    fi

    if [[ ${#to_addrs[@]} -eq 0 ]] || [[ -z "$subject" ]] || [[ -z "$body" ]]; then
        echo "Error: --to, --subject, and --body are all required"
        return 1
    fi

    for att_path in "${attachments[@]}"; do
        if [[ ! -f "$att_path" ]]; then
            echo "Error: Attachment not found: $att_path" >&2
            return 1
        fi
    done

    local esc_cc esc_bcc esc_from esc_subj esc_body
    esc_cc=$(osa_str "$cc_addr")
    esc_bcc=$(osa_str "$bcc_addr")
    esc_from=$(osa_str "$from_addr")
    esc_subj=$(osa_str "$subject")
    esc_body=$(osa_str "$body")

    local att_osa=""
    local att_count=${#attachments[@]}
    for att_path in "${attachments[@]}"; do
        local esc_att
        esc_att=$(osa_str "$att_path")
        att_osa+="        make new attachment with properties {file name: POSIX file \"${esc_att}\"} at end of content of newMessage"$'\n'
    done

    # Build to-recipients AppleScript block (supports multiple --to)
    local to_osa="" to_summary=""
    for addr in "${to_addrs[@]}"; do
        local esc_addr
        esc_addr=$(osa_str "$addr")
        to_osa+="        make new to recipient at end of to recipients with properties {address:\"${esc_addr}\"}"$'\n'
        [[ -n "$to_summary" ]] && to_summary+=", "
        to_summary+="$addr"
    done
    local esc_to_summary
    esc_to_summary=$(osa_str "$to_summary")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch

    set msgProps to {subject:"$esc_subj", content:"$esc_body"}
    if "$esc_from" is not "" then
        set msgProps to msgProps & {sender:"$esc_from"}
    end if

    set newMessage to make new outgoing message with properties msgProps
    tell newMessage
$to_osa
        if "$esc_cc" is not "" then
            make new cc recipient at end of cc recipients with properties {address:"$esc_cc"}
        end if
        if "$esc_bcc" is not "" then
            make new bcc recipient at end of bcc recipients with properties {address:"$esc_bcc"}
        end if
    end tell
$att_osa
    -- send 返回 "true if sending was successful, false if not"（Mail.sdef）。
    -- 以前丢弃返回值，发送被拒也报 "Sent"。
    set sendOK to false
    tell newMessage
        set sendOK to send
    end tell
    if sendOK is false then error "Mail did not accept the message for sending — check the account's outgoing server"

    set resultStr to "Sent ($att_count attachment(s)) → $esc_to_summary"
    if $att_count = 0 then set resultStr to "Sent → $esc_to_summary"
    if "$esc_cc" is not "" then set resultStr to resultStr & " | CC: $esc_cc"
    if "$esc_bcc" is not "" then set resultStr to resultStr & " | BCC: $esc_bcc"
    return resultStr
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# REPLY
# ─────────────────────────────────────────────
reply_email() {
    local email_id="$1"; shift
    local reply_body="" mailbox_name="inbox" reply_all="false" cc_addr="" bcc_addr=""
    local body_seen="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all|-a)     reply_all="true"; shift ;;
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            --cc|-c)      need_val "$1" "$#"; cc_addr="$2"; shift 2 ;;
            --bcc|-b)     need_val "$1" "$#"; bcc_addr="$2"; shift 2 ;;
            # 正文允许不带引号分成多个词，全部拼回去；flag 与正文的先后顺序因此不再影响结果
            *)            body_seen="true"; reply_body="${reply_body:+$reply_body }$1"; shift ;;
        esac
    done

    # 没有正文就不发信：此前 `reply <id> --all` 会给所有原收件人发一封空回复
    if [[ "$body_seen" != "true" ]]; then
        echo "Error: reply body required — usage: reply <id> \"your text\" [--all] [--cc <addr>]" >&2
        return 1
    fi

    local esc_body esc_mb esc_cc esc_bcc
    esc_body=$(osa_str "$reply_body")
    esc_mb=$(osa_str "$mailbox_name")
    esc_cc=$(osa_str "$cc_addr")
    esc_bcc=$(osa_str "$bcc_addr")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set originalSender to sender of targetMessage
    set replySubject to subject of targetMessage
    if replySubject does not start with "Re: " then set replySubject to "Re: " & replySubject

    -- 构造回复对象与发送分成两步：只有「构造」失败才降级为新建消息；
    -- 发送放在 try 之外，避免 send 抛错后被降级分支再发一封（重复投递）。
    set replyMessage to missing value
    try
        if $reply_all then
            set replyMessage to reply targetMessage with reply to all
        else
            set replyMessage to reply targetMessage
        end if
    on error
        set replyMessage to missing value
    end try

    set isReplyObject to (replyMessage is not missing value)
    if isReplyObject then
        tell replyMessage to set content to "$esc_body" & return & return & content
    else
        set replyMessage to make new outgoing message with properties {subject:replySubject, content:"$esc_body"}
        tell replyMessage
            make new to recipient at end of to recipients with properties {address:originalSender}
        end tell
    end if

    tell replyMessage
        if "$esc_cc" is not "" then
            make new cc recipient at end of cc recipients with properties {address:"$esc_cc"}
        end if
        if "$esc_bcc" is not "" then
            make new bcc recipient at end of bcc recipients with properties {address:"$esc_bcc"}
        end if
        set sendOK to send
    end tell

    if sendOK is false then error "Mail refused to send the reply — check the account's outgoing server"

    set resultStr to "Reply sent → " & originalSender
    if $reply_all then set resultStr to resultStr & " (reply-all)"
    if not isReplyObject then set resultStr to resultStr & " [fallback: original thread not quoted]"
    if "$esc_cc" is not "" then set resultStr to resultStr & " | CC: $esc_cc"
    if "$esc_bcc" is not "" then set resultStr to resultStr & " | BCC: $esc_bcc"
    return resultStr
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# FORWARD
# ─────────────────────────────────────────────
forward_email() {
    local email_id="$1"; shift
    local to_addr="" extra_body="" mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to|-t)      need_val "$1" "$#"; to_addr="$2"; shift 2 ;;
            --body|-b)    need_val "$1" "$#"; extra_body="$2"; shift 2 ;;
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$to_addr" ]]; then echo "Error: --to <address> required"; return 1; fi

    local esc_to esc_body esc_mb
    esc_to=$(osa_str "$to_addr")
    esc_body=$(osa_str "$extra_body")
    esc_mb=$(osa_str "$mailbox_name")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set fwdMessage to forward targetMessage
    tell fwdMessage
        make new to recipient at end of to recipients with properties {address:"$esc_to"}
        if "$esc_body" is not "" then
            set content to "$esc_body" & return & return & content
        end if
        send
    end tell
    return "Forwarded → $esc_to"
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# DRAFT
# ─────────────────────────────────────────────
save_draft() {
    local to_addr="" cc_addr="" subject="" body=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to|-t)      need_val "$1" "$#"; to_addr="$2"; shift 2 ;;
            --cc|-c)      need_val "$1" "$#"; cc_addr="$2"; shift 2 ;;
            --subject|-s) need_val "$1" "$#"; subject="$2"; shift 2 ;;
            --body|-B)    need_val "$1" "$#"; body="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local esc_to esc_cc esc_subj esc_body
    esc_to=$(osa_str "$to_addr")
    esc_cc=$(osa_str "$cc_addr")
    esc_subj=$(osa_str "$subject")
    esc_body=$(osa_str "$body")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
    -- visible 默认为 false；不设它、也不调用 save 的话，这个 outgoing message
    -- 既不在 Drafts 也不在发件队列里，函数返回后对象就没了（用户看到
    -- "Draft saved" 却找不到草稿）。
    set draftMsg to make new outgoing message with properties {subject:"$esc_subj", content:"$esc_body", visible:true}
    tell draftMsg
        if "$esc_to" is not "" then
            make new to recipient at end of to recipients with properties {address:"$esc_to"}
        end if
        if "$esc_cc" is not "" then
            make new cc recipient at end of cc recipients with properties {address:"$esc_cc"}
        end if
        save
    end tell
    set draftSubject to subject of draftMsg
    try
        close draftMsg saving yes
    end try
    return "Draft saved: \"" & draftSubject & "\""
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# FLAG / UNFLAG
# ─────────────────────────────────────────────
flag_email() {
    local email_id="$1" flag_state="$2"; shift 2
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local action_word
    [[ "$flag_state" == "true" ]] && action_word="Flagged" || action_word="Unflagged"
    local esc_mb
    esc_mb=$(osa_str "$mailbox_name")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")
    set flagged status of targetMessage to $flag_state
    return "$action_word: " & (subject of targetMessage)
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# MARK READ / UNREAD
# ─────────────────────────────────────────────
mark_email() {
    local email_id="$1" read_state="$2"; shift 2
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local action_word
    [[ "$read_state" == "true" ]] && action_word="Marked read" || action_word="Marked unread"

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")
    set read status of targetMessage to $read_state
    return "$action_word: " & (subject of targetMessage)
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# MOVE
# ─────────────────────────────────────────────
move_email() {
    local email_id="$1" dest_name="$2"; shift 2
    local src_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; src_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local esc_dest
    esc_dest=$(osa_str "$dest_name")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$src_name")
$(find_msg "$email_id" "$src_name")
    set msgSubject to subject of targetMessage
$(mb_resolve "$dest_name" | sed 's/targetMailbox/destMailbox/g')
    move targetMessage to destMailbox
    return "Moved \"" & msgSubject & "\" → $esc_dest"
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# TRASH
# ─────────────────────────────────────────────
trash_email() {
    local email_id="$1"; shift
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")
    set msgSubject to subject of targetMessage
    delete targetMessage
    return "Moved to trash: \"" & msgSubject & "\""
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# UNREAD COUNT
# ─────────────────────────────────────────────
count_unread() {
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local esc_mb
    esc_mb=$(osa_str "$mailbox_name")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
    set unreadCount to (count of (messages of targetMailbox whose read status is false))
    set totalCount to (count of messages of targetMailbox)
    return "Mailbox: $esc_mb" & linefeed & "Unread: " & unreadCount & " / " & totalCount & " total"
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# THREAD
# ─────────────────────────────────────────────
get_thread() {
    local email_id="$1"; shift
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set baseSubject to subject of targetMessage as string
    if baseSubject starts with "Re: " then set baseSubject to text 5 thru -1 of baseSubject
    if baseSubject starts with "Fwd: " then set baseSubject to text 6 thru -1 of baseSubject
    if baseSubject starts with "FW: " then set baseSubject to text 5 thru -1 of baseSubject
    if baseSubject starts with "RE: " then set baseSubject to text 5 thru -1 of baseSubject

    set threadMessages to {}
    repeat with msg in messages of targetMailbox
        set s to subject of msg as string
        if s starts with "Re: " then set s to text 5 thru -1 of s
        if s starts with "Fwd: " then set s to text 6 thru -1 of s
        if s starts with "FW: " then set s to text 5 thru -1 of s
        if s starts with "RE: " then set s to text 5 thru -1 of s
        if s is baseSubject then set end of threadMessages to msg
    end repeat

    set output to "Thread: \"" & baseSubject & "\" — " & (count of threadMessages) & " message(s)" & linefeed
    set output to output & "======================================" & linefeed

    repeat with msg in threadMessages
        set readStatus to "[ ]"
        if read status of msg then set readStatus to "[READ]"
        set output to output & "ID:" & (id of msg as string) & " " & readStatus & " | " & (date received of msg as string) & " | " & (sender of msg) & " | " & (subject of msg) & linefeed
    end repeat

    return output
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# THREAD READ
# ─────────────────────────────────────────────
thread_read() {
    local email_id="$1"; shift
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local esc_mb
    esc_mb=$(osa_str "$mailbox_name")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set baseSubject to subject of targetMessage
    repeat
        if baseSubject starts with "Re: " then
            set baseSubject to text 5 thru end of baseSubject
        else if baseSubject starts with "Fwd: " then
            set baseSubject to text 6 thru end of baseSubject
        else if baseSubject starts with "RE: " then
            set baseSubject to text 5 thru end of baseSubject
        else if baseSubject starts with "FW: " then
            set baseSubject to text 5 thru end of baseSubject
        else
            exit repeat
        end if
    end repeat

    set threadMsgs to {}
    repeat with msg in messages of targetMailbox
        set msgSubj to subject of msg
        repeat
            if msgSubj starts with "Re: " then
                set msgSubj to text 5 thru end of msgSubj
            else if msgSubj starts with "Fwd: " then
                set msgSubj to text 6 thru end of msgSubj
            else if msgSubj starts with "RE: " then
                set msgSubj to text 5 thru end of msgSubj
            else if msgSubj starts with "FW: " then
                set msgSubj to text 5 thru end of msgSubj
            else
                exit repeat
            end if
        end repeat
        if msgSubj is baseSubject then
            set end of threadMsgs to msg
        end if
    end repeat

    set threadCount to count of threadMsgs
    set output to "Thread: \"" & baseSubject & "\" — " & threadCount & " message(s)" & linefeed
    set output to output & "======================================" & linefeed

    set msgIndex to 0
    repeat with msg in threadMsgs
        set msgIndex to msgIndex + 1
        set output to output & "[" & msgIndex & "/" & threadCount & "] " & (sender of msg) & " | " & (date received of msg as string) & " | ID: " & (id of msg as string) & linefeed
        set output to output & "--------------------------------------" & linefeed
        set output to output & (content of msg) & linefeed
        set output to output & linefeed
    end repeat

    return output
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# SAVE ATTACHMENT
# ─────────────────────────────────────────────
save_attachment() {
    local email_id="$1"; shift
    local mailbox_name="inbox" out_dir="$HOME/Downloads"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            --out|-o)     need_val "$1" "$#"; out_dir="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$email_id" ]]; then echo "Error: Email ID required" >&2; return 1; fi

    mkdir -p "$out_dir" 2>/dev/null

    local esc_out
    esc_out=$(osa_str "$out_dir")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set attList to mail attachments of targetMessage
    set attCount to count of attList
    if attCount = 0 then
        return "No attachments found on email ID $email_id"
    end if

    set savedFiles to ""
    repeat with att in attList
        set attName to name of att
        set outPath to "$esc_out/" & attName
        try
            save att in POSIX file outPath
            set savedFiles to savedFiles & "Saved: " & attName & " → " & outPath & linefeed
        on error errMsg
            set savedFiles to savedFiles & "Error saving " & attName & ": " & errMsg & linefeed
        end try
    end repeat

    return "Saved " & attCount & " attachment(s):" & linefeed & savedFiles
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# ATTACHMENTS
# ─────────────────────────────────────────────
list_attachments() {
    local email_id="$1"; shift
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set attList to mail attachments of targetMessage
    if (count of attList) = 0 then
        return "No attachments in: " & (subject of targetMessage)
    end if

    set output to "Attachments for: \"" & (subject of targetMessage) & "\"" & linefeed
    set output to output & "======================================" & linefeed
    set n to 1

    repeat with att in attList
        -- name / mime type 都可能抛 -10000（Mail 对某些真附件不返回 MIME，
        -- 已实测 .pkpass 会让整个命令失败），逐属性容错而不是整体崩掉
        set attName to missing value
        try
            set attName to name of att
        end try
        if attName is missing value then set attName to "(unnamed)"
        set attMime to ""
        try
            set attMime to mime type of att
        end try
        if attMime is missing value then set attMime to ""
        try
            set output to output & n & ". " & attName & " | " & attMime & " | " & (file size of att) & " bytes" & linefeed
        on error
            set output to output & n & ". " & attName & " | " & attMime & linefeed
        end try
        set n to n + 1
    end repeat

    return output
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# EXPORT TO MARKDOWN
# ─────────────────────────────────────────────
export_email() {
    local email_id="$1"; shift
    local mailbox_name="inbox" out_path=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            --out|-o)     need_val "$1" "$#"; out_path="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$email_id" ]]; then echo "Error: Email ID required" >&2; return 1; fi

    local raw
    raw=$(osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set msgSubject to subject of targetMessage
    set msgSender to sender of targetMessage
    set msgDate to date received of targetMessage
    set msgBody to content of targetMessage

    set toAddrs to ""
    try
        repeat with r in to recipients of targetMessage
            if toAddrs is not "" then set toAddrs to toAddrs & ", "
            set toAddrs to toAddrs & (address of r)
        end repeat
    end try

    set ccAddrs to ""
    try
        repeat with r in cc recipients of targetMessage
            if ccAddrs is not "" then set ccAddrs to ccAddrs & ", "
            set ccAddrs to ccAddrs & (address of r)
        end repeat
    end try

    set attNames to ""
    try
        repeat with att in mail attachments of targetMessage
            if attNames is not "" then set attNames to attNames & ", "
            set attNames to attNames & (name of att)
        end repeat
    end try

    return msgSubject & "|||" & msgSender & "|||" & (msgDate as string) & "|||" & toAddrs & "|||" & ccAddrs & "|||" & attNames & "|||" & msgBody
end tell
OSAEOF
)
    if [[ $? -ne 0 || -z "$raw" ]]; then
        echo "Error: failed to export email $email_id" >&2
        return 1
    fi

    local subj sender date_str to_str cc_str att_str body_str
    subj=$(printf '%s\a' "$raw" | awk 'BEGIN{RS="\a"; FS="\\|\\|\\|"} {print $1}')
    sender=$(printf '%s\a' "$raw" | awk 'BEGIN{RS="\a"; FS="\\|\\|\\|"} {print $2}')
    date_str=$(printf '%s\a' "$raw" | awk 'BEGIN{RS="\a"; FS="\\|\\|\\|"} {print $3}')
    to_str=$(printf '%s\a' "$raw" | awk 'BEGIN{RS="\a"; FS="\\|\\|\\|"} {print $4}')
    cc_str=$(printf '%s\a' "$raw" | awk 'BEGIN{RS="\a"; FS="\\|\\|\\|"} {print $5}')
    att_str=$(printf '%s\a' "$raw" | awk 'BEGIN{RS="\a"; FS="\\|\\|\\|"} {print $6}')
    body_str=$(printf '%s\a' "$raw" | awk 'BEGIN{RS="\a"; FS="\\|\\|\\|"} {print $7}')
    local nl
    nl=$(printf '\n')
    subj="${subj//$nl/ }"
    sender="${sender//$nl/ }"
    date_str="${date_str//$nl/ }"
    to_str="${to_str//$nl/ }"
    cc_str="${cc_str//$nl/ }"
    att_str="${att_str//$nl/ }"

    local today
    today=$(date '+%Y-%m-%d')
    if [[ -z "$out_path" ]]; then
        local safe_subj
        safe_subj=$(echo "$subj" | tr '/:*?"<>|\\' '-' | cut -c1-60)
        out_path="$HOME/Downloads/${today} ${safe_subj}.email.md"
    fi

    local sender_email
    sender_email=$(echo "$sender" | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -1)

    {
        echo "---"
        echo "created: $today"
        echo "modified: $today"
        echo "document-type: email"
        echo "status: archive"
        echo "tags:"
        echo "  - email-archive"
        echo "from: ${sender_email:-$sender}"
        echo "to: $to_str"
        [[ -n "$cc_str" ]] && echo "cc: $cc_str"
        echo "subject: $subj"
        echo "date: $today"
        echo "email-id: $email_id"
        echo "---"
        echo "# $subj"
        echo ""
        echo "**From:** $sender"
        [[ -n "$to_str" ]] && echo "**To:** $to_str"
        [[ -n "$cc_str" ]] && echo "**CC:** $cc_str"
        echo "**Date:** $date_str"
        echo ""
        echo "---"
        echo ""
        echo "$body_str"
        [[ -n "$att_str" ]] && echo "" && echo "**Attachments:** $att_str"
    } > "$out_path"

    echo "Exported: $out_path"
}

# ─────────────────────────────────────────────
# ARCHIVE
# ─────────────────────────────────────────────
archive_email() {
    local email_id="$1"; shift
    local mailbox_name="inbox"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m) need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$email_id" ]]; then echo "Error: Email ID required" >&2; return 1; fi

    local esc_mb
    esc_mb=$(osa_str "$mailbox_name")

    osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$(find_msg "$email_id" "$mailbox_name")

    set msgSubject to subject of targetMessage
    -- Archive 必须落在源邮件所属账户。用 mb_resolve 全局找一个 "Archive" 会命中
    -- 第一个同名邮箱（本机是 iCloud 的空 Archive），等于静默跨账户搬迁。
    set srcAcct to account of mailbox of targetMessage
    set destMailbox to missing value
    try
        set destMailbox to first mailbox of srcAcct whose name is "Archive"
    end try
    if destMailbox is missing value then error "Account " & (name of srcAcct) & " has no Archive mailbox — use move <id> <mailbox>"

    move targetMessage to destMailbox
    return "Archived: " & msgSubject & " → Archive (" & (name of srcAcct) & ")"
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# BULK OPERATIONS
# ─────────────────────────────────────────────
bulk_operation() {
    local op="$1"; shift
    local mailbox_name="" dest_name="" unread_only="false" confirm="false" force="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mailbox|-m)  need_val "$1" "$#"; mailbox_name="$2"; shift 2 ;;
            --dest|-d)     need_val "$1" "$#"; dest_name="$2"; shift 2 ;;
            --unread-only|-u) unread_only="true"; shift ;;
            --confirm|-c)  confirm="true"; shift ;;
            --force|-f)    force="true"; confirm="true"; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$mailbox_name" ]]; then
        echo "Error: --mailbox <name> required" >&2; return 1
    fi
    if [[ "$op" == "move" ]] && [[ -z "$dest_name" ]]; then
        echo "Error: --dest <folder> required for bulk-move" >&2; return 1
    fi

    # delete 对已在垃圾桶的邮件是空操作（Mail 没有 AppleScript 的 erase/expunge），
    # 但以前照样打印 "N message(s) processed" —— 用户会以为已经清掉。
    local m_lower
    m_lower=$(printf '%s' "$mailbox_name" | tr '[:upper:]' '[:lower:]')
    if [[ "$op" == "trash" ]] && { [[ "$m_lower" == "trash" ]] || [[ "$m_lower" == "deleted" ]] || [[ "$m_lower" == "deleted messages" ]]; }; then
        echo "Error: messages already in Deleted Messages cannot be removed by delete — Mail exposes no expunge in AppleScript. Use Mailbox > Erase Deleted Items in Mail.app." >&2
        return 1
    fi

    local esc_mb esc_dest
    esc_mb=$(osa_str "$mailbox_name")
    esc_dest=$(osa_str "$dest_name")

    local dest_osa=""
    if [[ "$op" == "move" ]]; then
        dest_osa=$(mb_resolve "$dest_name" | sed 's/targetMailbox/destMailbox/g')
    fi

    local action_osa=""
    case "$op" in
        trash)
            action_osa='delete msg_'
            ;;
        move)
            action_osa='move msg_ to destMailbox'
            ;;
        mark-read)
            action_osa='set read status of msg_ to true'
            ;;
    esac

    local filter_osa=""
    if [[ "$unread_only" == "true" ]]; then
        filter_osa='set msgList to (messages of targetMailbox whose read status is false)'
    else
        filter_osa='set msgList to messages of targetMailbox'
    fi

    # Always get count first
    local count_result
    count_result=$(osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
    $filter_osa
    return (count of msgList) as string
end tell
OSAEOF
)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    if [[ -z "$count_result" ]]; then
        echo "Error: could not count messages in: $mailbox_name" >&2
        return 1
    fi

    if [[ "$confirm" != "true" ]]; then
        echo "DRY-RUN: Would $op $count_result message(s) from: $mailbox_name"
        [[ "$op" == "move" ]] && echo "Destination: $dest_name"
        echo "Add --confirm to execute (with prompt) or --force to execute immediately."
        return 0
    fi

    if [[ "$force" != "true" ]]; then
        echo "This will $op $count_result message(s) from: $mailbox_name"
        [[ "$op" == "move" ]] && echo "Destination: $dest_name"
        read -r -p "Proceed? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            return 0
        fi
    fi

    local result rc
    result=$(osascript << OSAEOF
tell application "Mail"
    if not running then launch
$(mb_resolve "$mailbox_name")
$dest_osa
    $filter_osa
    set msgCount to count of msgList
    set okCount to 0
    set failCount to 0
    -- 逐条执行并分别容错：以前任何一条出错（IMAP 重排、目标不可达）都会中
    -- 断整批，而且不报告已经处理了多少条
    repeat with i from msgCount to 1 by -1
        try
            set msg_ to item i of msgList
            $action_osa
            set okCount to okCount + 1
        on error
            set failCount to failCount + 1
        end try
    end repeat
    return (okCount as string) & " " & (failCount as string) & " " & (msgCount as string)
end tell
OSAEOF
)
    rc=$?
    [[ $rc -ne 0 ]] && return $rc

    local ok_n fail_n total_n
    read -r ok_n fail_n total_n <<< "$result"
    echo "$op: $ok_n of $total_n message(s) processed from: $mailbox_name"
    if [[ "$fail_n" != "0" ]]; then
        echo "Error: $fail_n message(s) could not be processed" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────
# ACCOUNTS
# ─────────────────────────────────────────────
list_accounts() {
    osascript << OSAEOF
tell application "Mail"
    if not running then launch
    set output to "Configured Email Accounts" & linefeed
    set output to output & "======================================" & linefeed
    repeat with acct in accounts
        set output to output & "Name:    " & (name of acct) & linefeed
        set output to output & "Email:   " & (email addresses of acct) & linefeed
        set output to output & "Type:    " & (account type of acct as string) & linefeed
        set output to output & "Enabled: " & (enabled of acct) & linefeed
        set output to output & "--------------------------------------" & linefeed
    end repeat
    return output
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# FOLDERS
# ─────────────────────────────────────────────
list_folders() {
    osascript << OSAEOF
tell application "Mail"
    if not running then launch
    set output to "Mailbox Folders (unread / total)" & linefeed
    set output to output & "======================================" & linefeed

    try
        set uc to count of (messages of inbox whose read status is false)
        set output to output & "inbox          " & uc & " unread / " & (count of messages of inbox) & " total" & linefeed
    end try
    try
        set output to output & "sent           " & (count of messages of sent mailbox) & " messages" & linefeed
    end try
    try
        set output to output & "drafts         " & (count of messages of drafts mailbox) & " messages" & linefeed
    end try
    try
        set uc to count of (messages of trash mailbox whose read status is false)
        set output to output & "trash          " & uc & " unread / " & (count of messages of trash mailbox) & " total" & linefeed
    end try
    try
        set uc to count of (messages of junk mailbox whose read status is false)
        set output to output & "junk           " & uc & " unread / " & (count of messages of junk mailbox) & " total" & linefeed
    end try

    set output to output & linefeed

    repeat with acct in accounts
        set output to output & "── " & (name of acct) & " ──" & linefeed
        try
            repeat with mb in mailboxes of acct
                set mbName to name of mb
                set total to count of messages of mb
                try
                    set uc to count of (messages of mb whose read status is false)
                    if uc > 0 then
                        set output to output & "  " & mbName & "  (" & uc & " unread / " & total & " total)" & linefeed
                    else
                        set output to output & "  " & mbName & "  (" & total & ")" & linefeed
                    end if
                on error
                    set output to output & "  " & mbName & "  (" & total & ")" & linefeed
                end try
                -- Recurse into sub-mailboxes (up to 3 levels deep)
                try
                    if (count of mailboxes of mb) > 0 then
                        repeat with submb2 in mailboxes of mb
                            set sub2Name to name of submb2
                            set sub2Path to mbName & "/" & sub2Name
                            set sub2Total to count of messages of submb2
                            try
                                set sub2Uc to count of (messages of submb2 whose read status is false)
                                if sub2Uc > 0 then
                                    set output to output & "    " & sub2Path & "  (" & sub2Uc & " unread / " & sub2Total & " total)" & linefeed
                                else
                                    set output to output & "    " & sub2Path & "  (" & sub2Total & ")" & linefeed
                                end if
                            on error
                                set output to output & "    " & sub2Path & "  (" & sub2Total & ")" & linefeed
                            end try
                            -- Level 3
                            try
                                if (count of mailboxes of submb2) > 0 then
                                    repeat with submb3 in mailboxes of submb2
                                        set sub3Name to name of submb3
                                        set sub3Path to sub2Path & "/" & sub3Name
                                        set sub3Total to count of messages of submb3
                                        try
                                            set sub3Uc to count of (messages of submb3 whose read status is false)
                                            if sub3Uc > 0 then
                                                set output to output & "      " & sub3Path & "  (" & sub3Uc & " unread / " & sub3Total & " total)" & linefeed
                                            else
                                                set output to output & "      " & sub3Path & "  (" & sub3Total & ")" & linefeed
                                            end if
                                        on error
                                            set output to output & "      " & sub3Path & "  (" & sub3Total & ")" & linefeed
                                        end try
                                        -- Level 4
                                        try
                                            if (count of mailboxes of submb3) > 0 then
                                                repeat with submb4 in mailboxes of submb3
                                                    set sub4Name to name of submb4
                                                    set sub4Path to sub3Path & "/" & sub4Name
                                                    set sub4Total to count of messages of submb4
                                                    try
                                                        set sub4Uc to count of (messages of submb4 whose read status is false)
                                                        if sub4Uc > 0 then
                                                            set output to output & "        " & sub4Path & "  (" & sub4Uc & " unread / " & sub4Total & " total)" & linefeed
                                                        else
                                                            set output to output & "        " & sub4Path & "  (" & sub4Total & ")" & linefeed
                                                        end if
                                                    on error
                                                        set output to output & "        " & sub4Path & "  (" & sub4Total & ")" & linefeed
                                                    end try
                                                end repeat
                                            end if
                                        end try
                                    end repeat
                                end if
                            end try
                        end repeat
                    end if
                end try
            end repeat
        on error
            set output to output & "  (unable to list)" & linefeed
        end try
        set output to output & linefeed
    end repeat

    return output
end tell
OSAEOF
}

# ─────────────────────────────────────────────
# WATCH / MONITOR
# ─────────────────────────────────────────────
WATCH_PLIST="$HOME/Library/LaunchAgents/com.apple-mail-cli.watch.plist"
WATCH_CACHE="$HOME/.cache/apple-mail-watch"
WATCH_SCRIPT="$(cd "$(dirname "$0")" && pwd)/watch-check.sh"
WATCH_VIP="$(cd "$(dirname "$0")" && pwd)/watch-vip.txt"

watch_command() {
    local sub="${1:-status}"; shift 2>/dev/null || true

    case "$sub" in
        start)
            if launchctl list 2>/dev/null | grep -q "com.apple-mail-cli.watch"; then
                echo "Watch is already running."
                return 0
            fi
            mkdir -p "$WATCH_CACHE" "$(dirname "$WATCH_PLIST")"

            # 以前这里直接 launchctl load 一个从未被创建过的 plist（仓库里没有任何
            # 生成它的代码），失败也照常打印 "Watch started"。现在先生成 plist，
            # 再用 launchctl 自己确认是否真的注册上了。
            local esc_script esc_log
            esc_script=$(printf '%s' "$WATCH_SCRIPT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            esc_log=$(printf '%s' "$WATCH_CACHE/watch.log" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            cat > "$WATCH_PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.apple-mail-cli.watch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${esc_script}</string>
    </array>
    <key>StartInterval</key>
    <integer>120</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${esc_log}</string>
    <key>StandardErrorPath</key>
    <string>${esc_log}</string>
</dict>
</plist>
PLISTEOF

            # launchctl load 失败时退出码也可能是 0，所以不拿它当判据。
            launchctl load "$WATCH_PLIST" 2>/dev/null \
                || launchctl bootstrap "gui/$(id -u)" "$WATCH_PLIST" 2>/dev/null \
                || true
            if ! launchctl list 2>/dev/null | grep -q "com.apple-mail-cli.watch"; then
                echo "Error: launchd did not register com.apple-mail-cli.watch — see $WATCH_PLIST" >&2
                return 1
            fi
            echo "Watch started (checking every 2 minutes)."
            echo "Job:      $WATCH_PLIST"
            echo "VIP list: $WATCH_VIP"
            ;;
        stop)
            if ! launchctl list 2>/dev/null | grep -q "com.apple-mail-cli.watch"; then
                echo "Watch is not running."
                return 0
            fi
            launchctl unload "$WATCH_PLIST" 2>/dev/null \
                || launchctl bootout "gui/$(id -u)/com.apple-mail-cli.watch" 2>/dev/null \
                || true
            echo "Watch stopped."
            ;;
        status)
            if launchctl list 2>/dev/null | grep -q "com.apple-mail-cli.watch"; then
                echo "Watch: RUNNING"
            else
                echo "Watch: STOPPED"
            fi
            if [[ -f "$WATCH_CACHE/last-check.json" ]]; then
                local last_mod
                last_mod=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$WATCH_CACHE/last-check.json" 2>/dev/null || echo "unknown")
                local count
                count=$(STATE="$WATCH_CACHE/last-check.json" /usr/bin/python3 -c 'import json,os; print(len(json.load(open(os.environ["STATE"]))))' 2>/dev/null || echo "?")
                echo "Last check: $last_mod ($count unread cached)"
            else
                echo "No state file yet (watch hasn't run)."
            fi
            if [[ -f "$WATCH_VIP" ]]; then
                local vip_count
                vip_count=$(grep -vc -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$WATCH_VIP" 2>/dev/null || echo 0)
                echo "VIP senders: $vip_count configured"
            fi
            ;;
        log)
            local lines="${1:-30}"
            if [[ -f "$WATCH_CACHE/watch.log" ]]; then
                tail -n "$lines" "$WATCH_CACHE/watch.log"
            else
                echo "No log file yet."
            fi
            ;;
        vip)
            if [[ -f "$WATCH_VIP" ]]; then
                cat "$WATCH_VIP"
            else
                echo "No VIP file found at $WATCH_VIP"
            fi
            ;;
        vip-add)
            local entry="$1"
            [[ -z "$entry" ]] && { echo "Usage: watch vip-add <email-or-name-fragment>" >&2; return 1; }
            entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [[ -z "$entry" ]] && { echo "Error: empty sender" >&2; return 1; }
            # 去重：重复追加会让同一个 VIP 在列表里堆多行；以 # 开头的条目会被
            # is_vip 当成注释跳过，所以也挡住。
            if [[ -f "$WATCH_VIP" ]] && grep -qixF -- "$entry" "$WATCH_VIP"; then
                echo "'$entry' is already in the VIP list."
                return 0
            fi
            printf '%s\n' "$entry" >> "$WATCH_VIP"
            echo "Added '$entry' to VIP list."
            ;;
        check)
            echo "Running manual check..."
            bash "$WATCH_SCRIPT"
            ;;
        *)
            echo "Usage: apple-mail.sh watch <start|stop|status|log|vip|vip-add|check>"
            echo ""
            echo "  start    — Start background mail monitoring (launchd, every 2 min)"
            echo "  stop     — Stop background monitoring"
            echo "  status   — Show watch status, last check time, VIP count"
            echo "  log [N]  — Show last N lines of watch log (default 30)"
            echo "  vip      — Show VIP sender list"
            echo "  vip-add  — Add a sender to the VIP list"
            echo "  check    — Run a manual check now"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────
# MAIN DISPATCHER
# ─────────────────────────────────────────────
main() {
    if [[ $# -eq 0 ]]; then show_usage; exit 1; fi

    local command="$1"; shift

    case "${command}" in
        list|ls)
            list_emails "$@" ;;
        read|show|view)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required"; exit 1; }
            read_email "$@" ;;
        search|find|query)
            [[ $# -eq 0 ]] && { echo "Error: Search query required"; exit 1; }
            search_emails "$@" ;;
        send|compose|new)
            send_email "$@" ;;
        reply|respond)
            [[ $# -lt 2 ]] && { echo "Usage: reply <id> <body> [--all]"; exit 1; }
            reply_email "$@" ;;
        reply-all|replyall)
            [[ $# -lt 1 ]] && { echo "Usage: reply-all <id> <body> [--cc <addr>] [--mailbox <name>]" >&2; exit 1; }
            # 不再用 "$1" "$2" --all "${@:3}" 重拼参数：那会让 `--cc a@b` 变成正文、`--all` 变成 CC
            reply_email "$1" --all "${@:2}" ;;
        forward|fwd)
            forward_email "$@" ;;
        draft|save-draft)
            save_draft "$@" ;;
        flag|star)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required"; exit 1; }
            flag_email "$1" "true" "${@:2}" ;;
        unflag|unstar)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required"; exit 1; }
            flag_email "$1" "false" "${@:2}" ;;
        mark-read|markread)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required"; exit 1; }
            mark_email "$1" "true" "${@:2}" ;;
        mark-unread|markunread)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required"; exit 1; }
            mark_email "$1" "false" "${@:2}" ;;
        move)
            [[ $# -lt 2 ]] && { echo "Usage: move <id> <dest-mailbox> [--mailbox <src>]"; exit 1; }
            move_email "$@" ;;
        trash|delete|rm)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required"; exit 1; }
            trash_email "$@" ;;
        unread|count-unread)
            count_unread "$@" ;;
        thread|conversation)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required"; exit 1; }
            get_thread "$@" ;;
        attachments|attach|att)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required"; exit 1; }
            list_attachments "$@" ;;
        save-attachment|save-att|download-attachment)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required" >&2; exit 1; }
            save_attachment "$@" ;;
        bulk-trash)
            bulk_operation "trash" "$@" ;;
        bulk-move)
            bulk_operation "move" "$@" ;;
        bulk-mark-read|bulk-markread)
            bulk_operation "mark-read" "$@" ;;
        thread-read|threadread)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required" >&2; exit 1; }
            thread_read "$@" ;;
        export|export-email)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required" >&2; exit 1; }
            export_email "$@" ;;
        archive)
            [[ $# -eq 0 ]] && { echo "Error: Email ID required" >&2; exit 1; }
            archive_email "$@" ;;
        accounts|accts)
            list_accounts ;;
        folders|mailboxes|boxes)
            list_folders ;;
        watch|monitor)
            watch_command "$@" ;;
        help|--help|-h)
            show_usage ;;
        *)
            echo "Unknown command: ${command}"
            echo "Run 'apple-mail.sh help' for usage."
            exit 1 ;;
    esac
}

main "$@"
