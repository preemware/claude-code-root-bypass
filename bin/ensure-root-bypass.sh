#!/bin/bash
# ensure-root-bypass.sh — re-assert the root bypass patch after Claude Code updates.
#
# Two layers are defended:
#   1. ~/.claude/settings.json "env.IS_SANDBOX" = "1"  (primary, native)
#   2. ~/.bashrc `export IS_SANDBOX=1`                (fallback)
#
# The updater only replaces binaries under ~/.local/share/claude/versions/ and
# never touches ~/.claude/ or ~/.bashrc, so in practice nothing needs to change.
# This script exists to *verify* the patch survived and to repair it if a future
# update path (or manual edit) ever wipes it.
#
# Safe to run any time; idempotent.

set -euo pipefail

HOME="${HOME:-/root}"
SETTINGS="$HOME/.claude/settings.json"
BASHRC="$HOME/.bashrc"
MARKER="# Claude Code: allow bypass-permissions when running as root."

changed=0

# --- 1. settings.json -------------------------------------------------------
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$HOME/.claude"
  cat > "$SETTINGS" <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": { "IS_SANDBOX": "1" }
}
JSON
  echo "[ensure-root-bypass] created $SETTINGS with IS_SANDBOX=1"
  changed=1
else
  # Use python3 to surgically set env.IS_SANDBOX without reformatting the file.
  if python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
env = data.setdefault("env", {})
if env.get("IS_SANDBOX") != "1":
    env["IS_SANDBOX"] = "1"
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    sys.exit(0)  # changed
sys.exit(1)      # already set
PY
  then
    echo "[ensure-root-bypass] repaired env.IS_SANDBOX in $SETTINGS"
    changed=1
  fi
fi

# --- 2. ~/.bashrc -----------------------------------------------------------
# Marker guards the whole block (export + wrapper). If either is missing,
# wipe any partial remnants and re-append the canonical block.
if ! grep -qF "$MARKER" "$BASHRC" 2>/dev/null || ! grep -qF 'claude() {' "$BASHRC" 2>/dev/null; then
  # Drop any stale partial block (from an older repair or manual edit).
  if grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
    sed -i '/# Claude Code: allow bypass-permissions/,$d' "$BASHRC"
  fi
  cat >> "$BASHRC" <<'SH'

# Claude Code: allow bypass-permissions when running as root.
# isRootOutsideDeliberateSandbox() skips the block when IS_SANDBOX=1.
# Redundant with ~/.claude/settings.json env block; survives settings rewrites.
export IS_SANDBOX=1

# Re-assert the root bypass after manual `claude update` runs.
claude() {
  command claude "$@"
  local rc=$?
  if [[ "$1" == "update" || "$1" == "upgrade" ]]; then
    "$HOME/.claude/ensure-root-bypass.sh" || true
  fi
  return $rc
}
SH
  echo "[ensure-root-bypass] appended IS_SANDBOX block to $BASHRC"
  changed=1
fi

# --- 3. smoke test (only if claude is on PATH) ------------------------------
if command -v claude >/dev/null 2>&1; then
  if IS_SANDBOX=1 timeout 25 claude --dangerously-skip-permissions \
       -p "say OK" --max-turns 1 >/dev/null 2>&1; then
    : # pass
  else
    echo "[ensure-root-bypass] WARNING: smoke test failed — root bypass may not be active" >&2
    exit 2
  fi
fi

[ "$changed" = "1" ] && echo "[ensure-root-bypass] patch re-asserted" || true
exit 0
