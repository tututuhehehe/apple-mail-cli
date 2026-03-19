#!/bin/bash
#
# Apple Mail CLI Installer
# Checks prerequisites, copies files, and sets up a shell alias.
#

set -euo pipefail

INSTALL_DIR="${HOME}/.apple-mail-cli"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Apple Mail CLI — Installer"
echo "════════════════════════════════════════"
echo ""

# 1. Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: Apple Mail CLI requires macOS. Detected: $(uname)"
  exit 1
fi
echo "✓ macOS detected"

# 2. Check macOS version
SW_VERS=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
echo "✓ macOS ${SW_VERS}"

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
chmod +x "$INSTALL_DIR/apple-mail.sh" "$INSTALL_DIR/bulk-unsubscribe.sh" "$INSTALL_DIR/watch-check.sh" "$INSTALL_DIR/test-apple-mail.sh"
echo "✓ Files copied to ${INSTALL_DIR}"

# 6. Set up alias
SHELL_NAME="$(basename "$SHELL")"
case "$SHELL_NAME" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash) RC_FILE="$HOME/.bashrc" ;;
  *)    RC_FILE="" ;;
esac

ALIAS_LINE="alias amail=\"bash ${INSTALL_DIR}/apple-mail.sh\""

if [[ -n "$RC_FILE" ]]; then
  if grep -q "alias amail=" "$RC_FILE" 2>/dev/null; then
    echo "✓ Alias 'amail' already exists in ${RC_FILE}"
  else
    read -p "Add 'amail' alias to ${RC_FILE}? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo "" >> "$RC_FILE"
      echo "# Apple Mail CLI" >> "$RC_FILE"
      echo "$ALIAS_LINE" >> "$RC_FILE"
      echo "✓ Alias added. Run 'source ${RC_FILE}' or open a new terminal."
    else
      echo "  To add manually:"
      echo "  echo '${ALIAS_LINE}' >> ${RC_FILE}"
    fi
  fi
else
  echo "  Add this alias to your shell profile:"
  echo "  ${ALIAS_LINE}"
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
