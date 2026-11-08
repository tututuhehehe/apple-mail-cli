#!/bin/bash
#
# Apple Mail Skill — Smoke Test Suite
# 此套件不得执行任何写操作。
# Read-only Mail.app commands, plus argument checks that fail before a
# message is created, moved, deleted, flagged, or exported.
# bulk-* is never pointed at a real mailbox: even the dry-run counts live
# mail, and if that default changed the test would empty the mailbox.
#
# Usage: bash test-apple-mail.sh
#

SCRIPT="$(cd "$(dirname "$0")" && pwd)/apple-mail.sh"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  - $1 (skipped)"; SKIP=$((SKIP + 1)); }

shorten() {
  local s
  s=$(printf '%s' "$1" | tr '\n' ' ')
  if [[ ${#s} -gt 200 ]]; then
    printf '%s' "${s:0:200}..."
  else
    printf '%s' "$s"
  fi
}

# Success path: exit 0, empty stderr, non-empty stdout matching $2 (grep -E).
# A syntax/execution error on stdout is a failure even if some other token matches.
run_test() {
  local name="$1" pattern="$2"
  shift 2
  local out err output stderr
  out=$(mktemp "${TMPDIR:-/tmp}/amail-out.XXXXXX")
  err=$(mktemp "${TMPDIR:-/tmp}/amail-err.XXXXXX")
  "$SCRIPT" "$@" >"$out" 2>"$err"
  local exit_code=$?
  output=$(cat "$out")
  stderr=$(cat "$err")
  rm -f "$out" "$err"

  if [[ $exit_code -ne 0 ]]; then
    fail "$name → exit $exit_code: $(shorten "${stderr:-$output}")"
    return
  fi
  if [[ -n "$stderr" ]]; then
    fail "$name → unexpected stderr: $(shorten "$stderr")"
    return
  fi
  if [[ -z "$output" ]]; then
    fail "$name → empty stdout"
    return
  fi
  if printf '%s\n' "$output" | grep -Eq 'syntax error|execution error'; then
    fail "$name → AppleScript error in stdout: $(shorten "$output")"
    return
  fi
  if ! printf '%s\n' "$output" | grep -Eq "$pattern"; then
    fail "$name → output missing /${pattern}/: $(shorten "$output")"
    return
  fi
  pass "$name"
}

# Failure path: non-zero exit and an error message (stdout or stderr).
run_fail() {
  local name="$1" pattern="$2"
  shift 2
  local out err output stderr combined
  out=$(mktemp "${TMPDIR:-/tmp}/amail-out.XXXXXX")
  err=$(mktemp "${TMPDIR:-/tmp}/amail-err.XXXXXX")
  "$SCRIPT" "$@" >"$out" 2>"$err"
  local exit_code=$?
  output=$(cat "$out")
  stderr=$(cat "$err")
  rm -f "$out" "$err"
  combined="${output}
${stderr}"

  if [[ $exit_code -eq 0 ]]; then
    fail "$name → expected non-zero exit, got 0: $(shorten "$combined")"
    return
  fi
  if [[ -z "$output" && -z "$stderr" ]]; then
    fail "$name → exit $exit_code but no error output"
    return
  fi
  if [[ -n "$pattern" ]] && ! printf '%s\n' "$combined" | grep -Eq "$pattern"; then
    fail "$name → exit $exit_code but output missing /${pattern}/: $(shorten "$combined")"
    return
  fi
  pass "$name"
}

VERSION=$(grep -m1 '^VERSION=' "$SCRIPT" | sed 's/^VERSION="//; s/"$//')
[[ -z "$VERSION" ]] && VERSION="unknown"

echo ""
echo "Apple Mail Skill v${VERSION} — Smoke Test"
echo "======================================"
echo ""

echo "── INFO COMMANDS ──"
run_test "accounts" "Configured Email Accounts" accounts
run_test "folders" "Mailbox Folders" folders

echo ""
echo "── LISTING ──"
run_test "list inbox (5)" "ID:|No messages in:" list 5
run_test "list --unread" "ID:|No unread messages in:" list --unread
run_test "list sent (3)" "ID:|No messages in:" list --mailbox sent 3

echo ""
echo "── UNREAD COUNT ──"
run_test "unread inbox" "Unread:" unread
run_test "unread sent" "Unread:" unread --mailbox sent

echo ""
echo "── SEARCH ──"
run_test "search inbox (subject)" "ID:|No results for:" search "the" 3
run_test "search --mailbox all" "ID:|No results for:" search "the" --mailbox all 3
run_test "search --from filter" "ID:|No results for:" search "the" --from "@" --mailbox all 5
run_test "search --after date" "ID:|No results for:" search "the" --after 2026-01-01 --mailbox all 3

echo ""
echo "── READ (uses first inbox message) ──"
list_out=$(mktemp "${TMPDIR:-/tmp}/amail-out.XXXXXX")
list_err=$(mktemp "${TMPDIR:-/tmp}/amail-err.XXXXXX")
"$SCRIPT" list 30 >"$list_out" 2>"$list_err"
list_rc=$?
ANY_ID=$(awk '/^ID:/ { sub(/^ID:/, "", $1); print $1; exit }' "$list_out")
# `read` sets the message's read status. Prefer a message that is already
# read so the unread count does not change. Never flip an unread message.
READ_ID=$(awk '/^ID:/ && /\[READ\]/ { sub(/^ID:/, "", $1); print $1; exit }' "$list_out")
if [[ $list_rc -ne 0 ]]; then
  reason="list 30 exited ${list_rc}: $(shorten "$(cat "$list_err"; cat "$list_out")")"
  skip "read <id> — ${reason}"
  skip "attachments <id> — ${reason}"
  skip "thread <id> — ${reason}"
  skip "thread-read <id> — ${reason}"
elif [[ -z "$ANY_ID" ]]; then
  reason="list 30 had no ID: line (inbox empty or unexpected format)"
  skip "read <id> — ${reason}"
  skip "attachments <id> — ${reason}"
  skip "thread <id> — ${reason}"
  skip "thread-read <id> — ${reason}"
else
  if [[ -n "$READ_ID" ]]; then
    run_test "read <id>" "Subject:" read "$READ_ID"
  else
    skip "read <id> — only unread mail is available; read would mark it read, and this suite must not write"
  fi
  run_test "attachments <id>" "Attachments for:|No attachments" attachments "$ANY_ID"
  run_test "thread <id>" "^Thread:" thread "$ANY_ID"
  run_test "thread-read <id>" "^Thread:" thread-read "$ANY_ID"
fi
rm -f "$list_out" "$list_err"

echo ""
echo "── WATCH (status only; start/stop/check/vip-add are not run) ──"
run_test "watch status" "^Watch:" watch status

echo ""
echo "── HELP ──"
run_test "help" "READING:" help
run_test "help documents bulk dry-run" "Default: dry-run" help

echo ""
echo "── ERROR PATHS (non-zero exit; no mailbox mutation) ──"
# Missing --mailbox returns before Mail.app counts or deletes anything.
# Do not add a mailbox name, --confirm, or --force to the bulk-* checks.
run_fail "read missing id" "Error:" read
run_fail "read unknown id" "not found|Error:" read 999999
run_fail "list missing mailbox" "Mailbox not found|Error:" list 2 --mailbox "不存在的邮箱-apple-mail-cli-smoke"
run_fail "send missing args" "required|Error:|Usage" send
run_fail "reply missing args" "Usage|Error:" reply
run_fail "forward missing to" "Error:|--to|Usage" forward
run_fail "draft missing option value" "requires a value|Error:" draft --to
run_fail "archive missing id" "Error:" archive
run_fail "save-attachment missing id" "Error:" save-attachment
run_fail "export missing id" "Error:" export
run_fail "bulk-trash missing mailbox" "Error:|--mailbox" bulk-trash
run_fail "unknown command" "Unknown command" definitely-not-a-command

echo ""
echo "══════════════════════════════════════"
echo "Results: $PASS passed | $FAIL failed | $SKIP skipped"
echo ""
if [[ $FAIL -eq 0 ]]; then
  if [[ $SKIP -gt 0 ]]; then
    echo "✓ No failures — $SKIP skipped (an empty mailbox is a valid state, not a failure)"
  else
    echo "✓ All tests passed — skill is healthy"
  fi
  exit 0
else
  echo "✗ $FAIL test(s) failed — investigate above"
  exit 1
fi
