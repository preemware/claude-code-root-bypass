#!/bin/sh
# Install the Claude Code root-bypass fix (applier + systemd watcher).
# Run as root on the host where the Claude Code desktop backend runs.
set -eu

[ "$(id -u)" = 0 ] || { echo "install.sh must run as root (try: sudo ./install.sh)" >&2; exit 1; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLAUDE_HOME=/root/.claude

echo "==> installing applier scripts into $CLAUDE_HOME"
install -d "$CLAUDE_HOME"
install -m 0755 "$HERE/bin/ensure-ccd-bypass.sh"  "$CLAUDE_HOME/ensure-ccd-bypass.sh"
install -m 0755 "$HERE/bin/ensure-root-bypass.sh" "$CLAUDE_HOME/ensure-root-bypass.sh"

echo "==> installing systemd units"
install -m 0644 "$HERE/systemd/claude-ccd-bypass.service" /etc/systemd/system/claude-ccd-bypass.service
install -m 0644 "$HERE/systemd/claude-ccd-bypass.path"    /etc/systemd/system/claude-ccd-bypass.path
install -m 0644 "$HERE/systemd/claude-ccd-bypass.timer"   /etc/systemd/system/claude-ccd-bypass.timer

echo "==> enabling watcher + fallback timer"
systemctl daemon-reload
systemctl enable --now claude-ccd-bypass.path claude-ccd-bypass.timer

echo "==> wrapping the current ccd-cli version now"
"$CLAUDE_HOME/ensure-ccd-bypass.sh"

cat <<'EOF'

Done. The fix applies to NEW sessions — start a fresh Claude Code session to get
Bypass Permissions (a session already running keeps its current mode).

  status : systemctl status claude-ccd-bypass.path
  logs   : journalctl -u claude-ccd-bypass.service -n 20 --no-pager

Optional (only needed for plain terminal `claude --dangerously-skip-permissions`, not the
desktop app): run  /root/.claude/ensure-root-bypass.sh  to persist IS_SANDBOX=1 into
settings.json / /etc/environment / ~/.bashrc. It runs a live `claude` smoke test.
EOF
