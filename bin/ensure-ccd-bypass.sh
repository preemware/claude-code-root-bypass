#!/bin/sh
# ensure-ccd-bypass.sh
# -----------------------------------------------------------------------------
# Keep "Bypass Permissions" available for the Claude Code desktop ("remote"/ccd)
# app when running as root.
#
# WHY: the desktop server launches each session as
#   /root/.claude/remote/ccd-cli/<version> ... --output-format stream-json --permission-mode acceptEdits
# The CLI's interactive permission resolver refuses bypassPermissions for uid 0
# unless the session is started with --dangerously-skip-permissions. Without it,
# the session silently downgrades to Accept Edits:
#   "Bypass permissions isn't available when running as root. The session
#    started in Accept edits instead."
#
# FIX: replace each versioned binary with a tiny wrapper that injects
# --dangerously-skip-permissions (and exports IS_SANDBOX=1 so the flag's own
# root guard passes) for real stream-json sessions only. The original binary is
# preserved as <version>.real.
#
# The app auto-updates and drops a fresh raw binary at a new <version> path,
# which wipes the injection. This script re-applies the wrapper to any
# unwrapped version and is driven by systemd (claude-ccd-bypass.path/.timer),
# so the fix survives updates. Idempotent; safe to run anytime.
#
# Revert everything:
#   systemctl disable --now claude-ccd-bypass.path claude-ccd-bypass.timer
#   rm -f /etc/systemd/system/claude-ccd-bypass.{path,service,timer}
#   systemctl daemon-reload
#   for f in /root/.claude/remote/ccd-cli/*.real; do mv -f "$f" "${f%.real}"; done
# -----------------------------------------------------------------------------
set -eu

CCD_DIR="/root/.claude/remote/ccd-cli"
LOG="/root/.claude/ccd-bypass.log"
LOCK="/root/.claude/.ccd-bypass.lock"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }

# Serialize: a systemd .path unit can fire several times during a download.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK" || true
  flock -n 9 || { log "another run holds the lock; exiting"; exit 0; }
fi

[ -d "$CCD_DIR" ] || { log "no $CCD_DIR yet; nothing to do"; exit 0; }

# True if $1 begins with the ELF magic (\x7fELF) -> a raw, unwrapped binary.
is_elf() {
  magic=$(dd if="$1" bs=1 count=4 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
  [ "$magic" = "7f454c46" ]
}

# True once $1's size is stable across a short window (download finished).
size_stable() {
  s1=$(stat -c %s "$1" 2>/dev/null || echo -1)
  sleep 2
  s2=$(stat -c %s "$1" 2>/dev/null || echo -2)
  [ "$s1" = "$s2" ] && [ "$s1" -gt 1000000 ]  # a real ccd binary is >100MB
}

write_wrapper() {  # $1 = versioned path (becomes the wrapper); $2 = .real path
  self="$1"; real="$2"; tmp="${self}.wrap.$$"
  cat >"$tmp" <<EOF
#!/bin/sh
# OPFORA patch: expose Bypass Permissions for interactive (stream-json) sessions as root.
# Auto-maintained by /root/.claude/ensure-ccd-bypass.sh. Revert: mv "$real" "$self"
export IS_SANDBOX=1
REAL="$real"
inject=1
case " \$* " in *" --dangerously-skip-permissions "*) inject=0 ;; esac
case " \$* " in *"stream-json"*) : ;; *) inject=0 ;; esac
if [ "\$inject" = 1 ]; then exec "\$REAL" --dangerously-skip-permissions "\$@"; fi
exec "\$REAL" "\$@"
EOF
  chmod 0755 "$tmp"
  mv -f "$tmp" "$self"   # atomic replace; $self is never absent (see caller)
}

changed=0
for f in "$CCD_DIR"/*; do
  [ -e "$f" ] || continue
  case "$f" in
    *.real|*.wrap.*) continue ;;                 # our artifacts
  esac
  base=$(basename "$f")
  case "$base" in
    [0-9]*.[0-9]*.[0-9]*) : ;;                    # version-shaped only
    *) continue ;;
  esac

  # Recovery: version path vanished but .real survived -> just rewrite wrapper.
  if [ ! -e "$f" ] && [ -e "$f.real" ] && is_elf "$f.real"; then
    write_wrapper "$f" "$f.real"; changed=1; log "recovered wrapper for $base"; continue
  fi

  # Already our wrapper? (starts with #!) -> nothing to do.
  if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then
    continue
  fi

  # A raw ELF sitting at the versioned path -> wrap it.
  if is_elf "$f"; then
    if ! size_stable "$f"; then
      log "$base still changing (download in progress?); will retry"
      continue
    fi
    # Point <version>.real at the current binary (create or refresh) WITHOUT
    # ever leaving <version> absent, then swap the wrapper in atomically.
    if ln -f "$f" "$f.real" 2>/dev/null || cp -f "$f" "$f.real"; then
      write_wrapper "$f" "$f.real"
      changed=1
      log "wrapped $base (real preserved as $base.real)"
    else
      log "ERROR: could not create $base.real; left $base untouched"
    fi
  fi
done

[ "$changed" = 1 ] && log "done (applied changes)" || log "done (already up to date)"
exit 0
