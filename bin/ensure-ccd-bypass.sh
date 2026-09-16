#!/bin/sh
# ensure-ccd-bypass.sh  (v2)
# -----------------------------------------------------------------------------
# Keep "Bypass Permissions" working as ROOT for the Claude Code desktop app AND
# the native CLI install, across the app's auto-updates.
#
# WHY v2: the desktop app launches sessions as
#   <binary> ... --output-format stream-json --permission-mode acceptEdits
# and, as root, the interactive resolver refuses bypassPermissions unless the
# session also carries --dangerously-skip-permissions. v1 wrapped only the
# desktop "remote" binaries (ccd-cli). But resuming a session pinned to a
# now-superseded version can fall back to the NATIVE install binary, which v1
# did not wrap -> no flag injected -> session downgrades to Accept Edits.
# (Reproduced: native <ver> + `--permission-mode acceptEdits` + no flag = acceptEdits.)
#
# v2 covers BOTH binary paths:
#   1. /root/.claude/remote/ccd-cli/<version>          (desktop "remote" sessions)
#   2. /root/.local/share/claude/versions/<version>    (native CLI + stale-version resumes)
# Each versioned binary becomes a wrapper that, FOR stream-json (SDK) sessions only,
# appends `--permission-mode bypassPermissions --dangerously-skip-permissions`
# (last flag wins, verified) and exports IS_SANDBOX=1. Non-stream-json calls
# (claude update / TUI / mcp / doctor / --version) pass through UNTOUCHED. The
# original binary is preserved as <version>.real.
#
# Every wrapper invocation is logged to /root/.claude/ccd-wrapper-invocations.log
# so any future acceptEdits resume is captured with its exact argv (or its ABSENCE
# there proves the launch never hit a wrapper).
#
# Driven by systemd claude-ccd-bypass.path (watches both dirs) + .timer. Idempotent.
#
# Revert everything:
#   systemctl disable --now claude-ccd-bypass.path claude-ccd-bypass.timer
#   rm -f /etc/systemd/system/claude-ccd-bypass.{path,service,timer}; systemctl daemon-reload
#   for d in /root/.claude/remote/ccd-cli /root/.local/share/claude/versions; do
#     for f in "$d"/*.real; do [ -e "$f" ] && mv -f "$f" "${f%.real}"; done
#   done
# -----------------------------------------------------------------------------
set -eu

MARKER="ccd-bypass-wrapper v2"
DIRS="/root/.claude/remote/ccd-cli /root/.local/share/claude/versions"
INVOKE_LOG="/root/.claude/ccd-wrapper-invocations.log"
LOG="/root/.claude/ccd-bypass.log"
LOCK="/root/.claude/.ccd-bypass.lock"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }

# Serialize: the .path unit can fire several times during a download.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK" || true
  flock -n 9 || { log "another run holds the lock; exiting"; exit 0; }
fi

# $1 begins with ELF magic (\x7fELF) -> a raw, unwrapped binary.
is_elf() {
  magic=$(dd if="$1" bs=1 count=4 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
  [ "$magic" = "7f454c46" ]
}
# $1's size is stable across a short window (download finished) and plausibly a real binary.
size_stable() {
  s1=$(stat -c %s "$1" 2>/dev/null || echo -1); sleep 2
  s2=$(stat -c %s "$1" 2>/dev/null || echo -2)
  [ "$s1" = "$s2" ] && [ "$s1" -gt 1000000 ]
}
# $1 is our current (v2) wrapper.
is_current_wrapper() {
  head -c 2 "$1" 2>/dev/null | grep -q '#!' && grep -q "$MARKER" "$1" 2>/dev/null
}

write_wrapper() {  # $1 = versioned path (becomes wrapper); $2 = .real path
  self="$1"; real="$2"; tmp="${self}.wrap.$$"
  cat >"$tmp" <<EOF
#!/bin/sh
# $MARKER  — auto-maintained by /root/.claude/ensure-ccd-bypass.sh
# Forces Bypass Permissions for root stream-json (SDK) sessions. Revert: mv "$real" "$self"
export IS_SANDBOX=1
REAL="$real"
inject=1
case " \$* " in *" --dangerously-skip-permissions "*) inject=0 ;; esac
case " \$* " in *stream-json*) : ;; *) inject=0 ;; esac
{ printf '%s bin=%s inject=%s argc=%s args=%s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\${0##*/}" "\$inject" "\$#" "\$(printf %s "\$*" | cut -c1-350)" >> "$INVOKE_LOG" ; } 2>/dev/null || true
if [ "\$inject" = 1 ]; then
  exec "\$REAL" "\$@" --permission-mode bypassPermissions --dangerously-skip-permissions
fi
exec "\$REAL" "\$@"
EOF
  chmod 0755 "$tmp"
  mv -f "$tmp" "$self"   # atomic; <version> is never absent (caller made .real first)
}

changed=0
for CCD_DIR in $DIRS; do
  [ -d "$CCD_DIR" ] || continue
  for f in "$CCD_DIR"/*; do
    [ -e "$f" ] || continue
    case "$f" in *.real|*.wrap.*) continue ;; esac
    base=$(basename "$f")
    case "$base" in [0-9]*.[0-9]*.[0-9]*) : ;; *) continue ;; esac

    if is_current_wrapper "$f"; then continue; fi

    # Older-template wrapper -> regenerate in place from its preserved .real.
    if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then
      if [ -e "$f.real" ] && is_elf "$f.real"; then
        write_wrapper "$f" "$f.real"; changed=1; log "upgraded wrapper $f"
      else
        log "WARN stale wrapper $f without valid .real; left as-is"
      fi
      continue
    fi

    # Raw ELF at the versioned path -> wrap it (guard against mid-download).
    if is_elf "$f"; then
      if ! size_stable "$f"; then log "$f still changing; will retry"; continue; fi
      if ln -f "$f" "$f.real" 2>/dev/null || cp -f "$f" "$f.real"; then
        write_wrapper "$f" "$f.real"; changed=1; log "wrapped $f (real=$base.real)"
      else
        log "ERROR could not create $f.real; left $f untouched"
      fi
    fi
  done
done

[ "$changed" = 1 ] && log "done (applied changes)" || log "done (already up to date)"
exit 0
