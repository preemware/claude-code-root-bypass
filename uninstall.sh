#!/bin/sh
# Remove the Claude Code root-bypass fix and restore original ccd-cli binaries.
set -u

[ "$(id -u)" = 0 ] || { echo "uninstall.sh must run as root (try: sudo ./uninstall.sh)" >&2; exit 1; }

echo "==> disabling + removing systemd units"
systemctl disable --now claude-ccd-bypass.path claude-ccd-bypass.timer 2>/dev/null || true
rm -f /etc/systemd/system/claude-ccd-bypass.path \
      /etc/systemd/system/claude-ccd-bypass.service \
      /etc/systemd/system/claude-ccd-bypass.timer
systemctl daemon-reload

echo "==> restoring original ccd-cli binaries from their .real backups"
CCD=/root/.claude/remote/ccd-cli
if [ -d "$CCD" ]; then
  for real in "$CCD"/*.real; do
    [ -e "$real" ] || continue
    mv -f "$real" "${real%.real}" && echo "    restored ${real%.real}"
  done
fi

rm -f /root/.claude/ensure-ccd-bypass.sh /root/.claude/.ccd-bypass.lock

cat <<'EOF'

Uninstalled. New sessions revert to the app's default (Accept Edits as root).
Note: IS_SANDBOX=1 entries in ~/.claude/settings.json, /etc/environment, and ~/.bashrc
are left intact. Remove them by hand if you also want those gone.
EOF
