# claude-code-root-bypass

Keep **Bypass Permissions** working in the Claude Code **desktop app** when it runs as
**root**, and keep it working across the app's auto-updates.

> Symptom this fixes:
>
> > **Bypass permissions isn't available when running as root. The session started in Accept edits instead.**

## Why this happens

There are two *independent* root checks in the Claude Code CLI, and they need different fixes:

1. **The `--dangerously-skip-permissions` flag guard.** As root it hard-exits with
   *"…cannot be used with root/sudo privileges…"* unless `IS_SANDBOX=1` (or
   `CLAUDE_CODE_BUBBLEWRAP`) is set. The internal check is roughly:

   ```js
   isRootOutsideDeliberateSandbox() =
     platform !== "win32" && getuid() === 0 && IS_SANDBOX !== "1" && !CLAUDE_CODE_BUBBLEWRAP
   ```

2. **The interactive permission-mode resolver.** When a session is started
   *interactively* (the desktop app uses `--input-format stream-json`), the resolver
   **refuses `bypassPermissions` for root and silently downgrades to `acceptEdits`**
   unless the session was launched with `--dangerously-skip-permissions`.
   `IS_SANDBOX` alone does **not** satisfy this one.

The desktop "remote" server launches every session as:

```
/root/.claude/remote/ccd-cli/<version> … --output-format stream-json --permission-mode acceptEdits
```

— i.e. **without** `--dangerously-skip-permissions`. So as root you always land in Accept
Edits. There is no server-side flag to change this; the only local interception point is
the versioned `ccd-cli/<version>` binary the server executes.

### The regression

The fix is to wrap that binary so it re-adds the flag. But the app **auto-updates** and
drops a fresh, unwrapped binary at a **new** `ccd-cli/<newversion>` path, wiping any
manual wrapper. That's why a one-off wrapper doesn't stay fixed.

## What this installs

| File | Purpose |
|------|---------|
| `/root/.claude/ensure-ccd-bypass.sh` | Idempotent applier. Replaces each `ccd-cli/<version>` raw binary with a tiny wrapper that injects `--dangerously-skip-permissions` (and `export IS_SANDBOX=1`) **for `stream-json` sessions only**; preserves the original as `<version>.real`. |
| `claude-ccd-bypass.path` (systemd) | Watches the `ccd-cli` dir and re-runs the applier **the instant an update drops a new binary**. |
| `claude-ccd-bypass.timer` (systemd) | 5-minute fallback poll, in case the path event is missed. |
| `claude-ccd-bypass.service` (systemd) | The oneshot the `.path`/`.timer` trigger. |
| `/root/.claude/ensure-root-bypass.sh` | Supplementary: keeps `IS_SANDBOX=1` in `~/.claude/settings.json`, `/etc/environment`, and `~/.bashrc` so a plain terminal `claude --dangerously-skip-permissions` works too. |

The wrapper injects the flag **only** for `stream-json` sessions, so utility calls the app
makes (`--version`, etc.) pass through untouched and never hit the flag's hard-exit.

## Install

Run as **root** on the host where the Claude Code desktop backend runs:

```sh
sudo ./install.sh
```

This copies the applier, installs and enables the systemd units, and wraps the current
version immediately.

> **Assumes the backend runs as root** (`~/.claude` = `/root/.claude`). Paths are
> hardcoded to `/root`; adjust the scripts/units if your setup differs.

## Verify

The fix applies to **new** sessions — a session that's already running keeps its mode.
Start a new Code session; it should come up in Bypass Permissions. To check the resolved
mode programmatically:

```sh
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' \
  | /root/.claude/remote/ccd-cli/"$(ls /root/.claude/remote/ccd-cli | grep -E '^[0-9]' | grep -v '\.real$' | sort -V | tail -1)" \
    --input-format stream-json --output-format stream-json --verbose \
    --setting-sources=user,project,local --permission-mode acceptEdits --max-turns 1 2>/dev/null \
  | grep -o '"permissionMode":"[^"]*"' | head -1
# expect: "permissionMode":"bypassPermissions"
```

Watcher activity:

```sh
systemctl status claude-ccd-bypass.path
journalctl -u claude-ccd-bypass.service --no-pager -n 20
```

## Uninstall

```sh
sudo ./uninstall.sh
```

Disables/removes the units and restores every wrapped `ccd-cli/<version>` from its
`.real` backup.

## Security note

Bypass Permissions disables Claude Code's permission prompts entirely. Only enable it on a
host you treat as a disposable sandbox (which is what `IS_SANDBOX=1` asserts). Do not run
this on a machine where an agent must not be able to act without approval.
