#!/bin/bash
#
# Apple Mail CLI Installer
# Checks prerequisites, copies files, and sets up a shell alias.
#

set -euo pipefail

INSTALL_DIR="${HOME}/.apple-mail-cli"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# BEGIN_TESTABLE
# Alias-install helpers. Kept together so a closed-stdin / fake-rc check can
# source this region without executing the installer.
BEGIN_MARK="# >>> apple-mail-cli >>>"
END_MARK="# <<< apple-mail-cli <<<"
TARGET_PREFIX="# apple-mail-cli-target: "

# Wrap $1 in single quotes, escaping any embedded single quote as '\'' .
quote_sq() {
  local rest="$1" out="'" chunk
  while [[ "$rest" == *"'"* ]]; do
    chunk="${rest%%"'"*}"
    out="${out}${chunk}'\\''"
    rest="${rest#*"'"}"
  done
  printf '%s' "${out}${rest}'"
}

# Double-quote a path for use inside a single-quoted alias value.
# awk program is single-quoted so backticks and dollars stay literal.
double_quote_path() {
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\$/, "\\$")
      gsub(/`/, "\\`")
      printf "\"%s\"", $0
    }
  '
}

# alias amail='bash "/path/with spaces/apple-mail.sh"'
alias_line_for() {
  local path="${1%/}/apple-mail.sh" body
  body="bash $(double_quote_path "$path")"
  printf 'alias amail=%s' "$(quote_sq "$body")"
}

target_comment_for() {
  printf '%s%s' "$TARGET_PREFIX" "${1%/}/apple-mail.sh"
}

strip_matching_quotes() {
  local val="$1" first rest last
  if [[ ${#val} -ge 2 ]]; then
    first=${val:0:1}
    rest=${val%?}
    last=${val#"$rest"}
    if [[ "$first" == "$last" && ( "$first" == "'" || "$first" == '"' ) ]]; then
      val=${val:1:${#val}-2}
    fi
  fi
  printf '%s' "$val"
}

# Path an existing amail alias points at, or empty if there is none.
# Prefers the marker block's target comment; falls back to parsing the alias
# so an install made by an older installer (no marker) is still detected.
existing_amail_target() {
  local rc="$1" from_block="" line="" val=""
  [[ -f "$rc" ]] || return 0
  if grep -qF "$BEGIN_MARK" "$rc"; then
    from_block=$(BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" TARGET_PREFIX="$TARGET_PREFIX" awk '
      BEGIN {
        begin = ENVIRON["BEGIN_MARK"]
        endm = ENVIRON["END_MARK"]
        prefix = ENVIRON["TARGET_PREFIX"]
      }
      $0 == begin { inside = 1; next }
      $0 == endm { inside = 0; next }
      inside && index($0, prefix) == 1 {
        print substr($0, length(prefix) + 1)
        exit
      }
    ' "$rc" || true)
    if [[ -n "$from_block" ]]; then
      printf '%s' "$from_block"
      return 0
    fi
  fi
  line=$(grep -E '^[[:space:]]*alias[[:space:]]+amail=' "$rc" || true)
  line=${line%%$'\n'*}
  [[ -z "$line" ]] && return 0
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val=$(strip_matching_quotes "$val")
  if [[ "$val" == bash* ]]; then
    val="${val#bash}"
    val="${val#"${val%%[![:space:]]*}"}"
  fi
  val=$(strip_matching_quotes "$val")
  if [[ "$val" == *apple-mail.sh* ]]; then
    val="${val%%apple-mail.sh*}apple-mail.sh"
  fi
  printf '%s' "$val"
}

backup_rc_once() {
  local rc="$1" bak="${1}.apple-mail-cli.bak"
  [[ -f "$rc" ]] || return 0
  if [[ -f "$bak" ]]; then
    echo "  Backup already exists: ${bak}"
    return 0
  fi
  cp "$rc" "$bak"
  echo "✓ Backed up ${rc} → ${bak}"
}

# mode: append | replace-block | replace-line
write_alias_block() {
  local rc="$1" mode="$2" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/amail-rc.XXXXXX")
  BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" \
    ALIAS_LINE="$ALIAS_LINE" TARGET_COMMENT="$TARGET_COMMENT" MODE="$mode" \
    awk '
      BEGIN {
        begin = ENVIRON["BEGIN_MARK"]
        endm = ENVIRON["END_MARK"]
        line = ENVIRON["ALIAS_LINE"]
        comment = ENVIRON["TARGET_COMMENT"]
        mode = ENVIRON["MODE"]
      }
      function emit() {
        print begin
        print comment
        print line
        print endm
      }
      mode == "replace-block" && $0 == begin {
        emit()
        skip = 1
        next
      }
      mode == "replace-block" && $0 == endm {
        skip = 0
        next
      }
      mode == "replace-block" && skip == 1 { next }
      mode == "replace-line" && !done && $0 ~ /^[[:space:]]*alias[[:space:]]+amail=/ {
        emit()
        done = 1
        next
      }
      { print }
      END {
        if (mode == "append") {
          print ""
          emit()
        }
      }
    ' "$rc" > "$tmp"
  mv "$tmp" "$rc"
}

# y/N prompt. Closed or non-interactive stdin takes the default (no) and
# returns non-zero without aborting under set -e.
confirm() {
  local prompt="$1" reply=""
  if [[ -t 0 ]]; then
    if ! read -r -p "$prompt [y/N] " -n 1 reply; then
      reply="n"
    fi
    echo ""
  else
    echo "${prompt} [y/N] → n (non-interactive; default is no)"
    reply="n"
  fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

answer_yes() {
  local prompt="$1" forced="${2:-}"
  if [[ -n "$forced" ]]; then
    [[ "$forced" =~ ^[Yy]([Ee][Ss])?$ ]]
    return
  fi
  confirm "$prompt"
}

# Install or update the amail alias in $1 so it points at $2/apple-mail.sh.
# Optional $3 (yes|no) skips the prompt — the installer itself never passes it.
# Returns 0 even when the user declines, so a non-interactive run continues.
sync_alias() {
  local rc="$1" install_dir="${2%/}" forced="${3:-}"
  local target="" mode="" want="${install_dir}/apple-mail.sh"

  ALIAS_LINE=$(alias_line_for "$install_dir")
  TARGET_COMMENT=$(target_comment_for "$install_dir")
  target=$(existing_amail_target "$rc" || true)

  if [[ -n "$target" && "$target" == "$want" ]]; then
    echo "✓ Alias 'amail' already points at ${want}"
    return 0
  fi

  if [[ -f "$rc" ]] && grep -qF "$BEGIN_MARK" "$rc"; then
    mode="replace-block"
  elif [[ -f "$rc" ]] && grep -qE '^[[:space:]]*alias[[:space:]]+amail=' "$rc"; then
    mode="replace-line"
  else
    mode="append"
  fi

  if [[ -n "$target" ]]; then
    echo "⚠ Alias 'amail' in ${rc} points to:"
    echo "    ${target}"
    echo "  This install is:"
    echo "    ${want}"
    if answer_yes "Replace it with the path above?" "$forced"; then
      backup_rc_once "$rc"
      [[ -f "$rc" ]] || touch "$rc"
      write_alias_block "$rc" "$mode"
      echo "✓ Alias updated. Run 'source ${rc}' or open a new terminal."
    else
      echo "  Left the existing alias unchanged."
      echo "  To update it, replace the apple-mail-cli block with:"
      echo "  ${BEGIN_MARK}"
      echo "  ${TARGET_COMMENT}"
      echo "  ${ALIAS_LINE}"
      echo "  ${END_MARK}"
    fi
  else
    if answer_yes "Add 'amail' alias to ${rc}?" "$forced"; then
      backup_rc_once "$rc"
      [[ -f "$rc" ]] || touch "$rc"
      write_alias_block "$rc" "$mode"
      echo "✓ Alias added. Run 'source ${rc}' or open a new terminal."
    else
      echo "  To add manually, append this block to ${rc}:"
      echo "  ${BEGIN_MARK}"
      echo "  ${TARGET_COMMENT}"
      echo "  ${ALIAS_LINE}"
      echo "  ${END_MARK}"
    fi
  fi
  return 0
}

# Warn (do not exit) when the version is missing or older than macOS 12.
report_macos_version() {
  local ver="$1" major
  if [[ -z "$ver" || "$ver" == "unknown" ]]; then
    echo "⚠ Could not read the macOS version (Apple Mail CLI targets macOS 12+). Continuing anyway."
    return 0
  fi
  major="${ver%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -lt 12 ]]; then
    echo "⚠ macOS ${ver} is older than 12. Apple Mail CLI targets macOS 12+. Continuing anyway."
  else
    echo "✓ macOS ${ver}"
  fi
}
# END_TESTABLE

echo "Apple Mail CLI — Installer"
echo "════════════════════════════════════════"
echo ""

# 1. Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: Apple Mail CLI requires macOS. Detected: $(uname)"
  exit 1
fi
echo "✓ macOS detected"

# 2. Check macOS version (warn below 12; do not abort — the claim is advisory)
SW_VERS=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
report_macos_version "$SW_VERS"

# 3. Check Mail.app
if [[ -d "/System/Applications/Mail.app" ]] || [[ -d "/Applications/Mail.app" ]]; then
  echo "✓ Mail.app found"
else
  echo "⚠ Mail.app not found — some commands may not work"
fi

# 4. Check osascript
if command -v osascript &> /dev/null; then
  echo "✓ osascript available"
else
  echo "ERROR: osascript not found — required for AppleScript execution"
  exit 1
fi

# 5. Copy files
echo ""
echo "Installing to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/apple-mail.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/bulk-unsubscribe.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/watch-check.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/test-apple-mail.sh" "$INSTALL_DIR/"
if [[ -f "$SCRIPT_DIR/watch-vip.txt" ]]; then
  cp "$SCRIPT_DIR/watch-vip.txt" "$INSTALL_DIR/"
elif [[ -f "$SCRIPT_DIR/watch-vip.txt.example" ]]; then
  cp "$SCRIPT_DIR/watch-vip.txt.example" "$INSTALL_DIR/watch-vip.txt"
fi
if [[ -d "$SCRIPT_DIR/skill" ]]; then
  mkdir -p "$INSTALL_DIR/skill"
  cp -R "$SCRIPT_DIR/skill/." "$INSTALL_DIR/skill/"
  echo "✓ Installed skill/ to ${INSTALL_DIR}/skill"
else
  echo "⚠ skill/ is not in this tree — the skill file was not installed and stays with the clone"
fi
chmod +x "$INSTALL_DIR/apple-mail.sh" "$INSTALL_DIR/bulk-unsubscribe.sh" "$INSTALL_DIR/watch-check.sh" "$INSTALL_DIR/test-apple-mail.sh"
echo "✓ Files copied to ${INSTALL_DIR}"

# 6. Set up alias
# ${SHELL} is unset in some non-login contexts; set -u would abort before
# the VIP note and the "Installation complete!" summary.
SHELL_NAME="$(basename "${SHELL:-/bin/zsh}")"
case "$SHELL_NAME" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash) RC_FILE="$HOME/.bashrc" ;;
  *)    RC_FILE="" ;;
esac

if [[ -n "$RC_FILE" ]]; then
  sync_alias "$RC_FILE" "$INSTALL_DIR"
else
  echo "  Add this alias block to your shell profile:"
  echo "  ${BEGIN_MARK}"
  echo "  $(target_comment_for "$INSTALL_DIR")"
  echo "  $(alias_line_for "$INSTALL_DIR")"
  echo "  ${END_MARK}"
fi

# 7. VIP setup reminder
echo ""
if [[ ! -f "$INSTALL_DIR/watch-vip.txt" ]] || grep -q "^# family.member" "$INSTALL_DIR/watch-vip.txt" 2>/dev/null; then
  echo "📝 Edit ${INSTALL_DIR}/watch-vip.txt with your VIP contacts for priority alerts"
fi

# 8. Verify
echo ""
echo "════════════════════════════════════════"
echo "Installation complete!"
echo ""
echo "Quick test:"
echo "  bash ${INSTALL_DIR}/apple-mail.sh accounts"
echo ""
echo "Or if alias was added:"
echo "  amail accounts"
echo "  amail list 10"
echo "  amail search \"meeting\" --mailbox all 5"
echo "  amail send --to user@example.com --subject \"Hello\" --body \"Test\""
