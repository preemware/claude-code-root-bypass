# claude-code-root-bypass

Keep **Bypass Permissions** working in Claude Code when it runs as **root** — for both
the **desktop app** and the **native CLI** — and keep it working across auto-updates.

> Symptom this fixes:
>
> > **Bypass permissions isn't available when running as root. The session started in Accept edits instead.**

## Why this happens

There are two *independent* root checks in the Claude Code CLI:

1. **The `--dangerously-skip-permissions` flag guard.** As root it hard-exits with
   *"…cannot be used with root/sudo privileges…"* unless `IS_SANDBOX=1` (or
   `CLAUDE_CODE_BUBBLEWRAP`) is set:

   ```js
   isRootOutsideDeliberateSandbox() =
     platform !== "win32" && getuid() === 0 && IS_SANDBOX !== "1" && !CLAUDE_CODE_BUBBLEWRAP
   ```

2. **The interactive permission-mode resolver.** For a `stream-json` (SDK/desktop) session,
   as root, it **refuses `bypassPermissions` and silently downgrades to `acceptEdits`**
   unless the session is launched with `--dangerously-skip-permissions`. The app always
   passes `--permission-mode acceptEdits`, so without the flag a root session lands in
   Accept Edits. `IS_SANDBOX` alone does **not** satisfy this check.

Sessions launch from **two different binary locations**, and both must be handled:

| Path | Used by |
|---|---|
| `/root/.claude/remote/ccd-cli/<version>` | desktop "remote" app sessions |
| `/root/.local/share/claude/versions/<version>` | native CLI (`/root/.local/bin/claude`), **and desktop resumes of a session pinned to a now-superseded version** |

### The regressions this has survived

- **App auto-update** drops a fresh, unwrapped binary at a **new** `ccd-cli/<newversion>`
  path, wiping any manual wrapper. → handled by the systemd watcher.
- **Resuming a session after a version bump** can fall back to the **native install
  binary**, which a ccd-cli-only fix never wrapped → no flag → Accept Edits.
  → handled by wrapping the native dir too (v2).

## What this installs

| File | Purpose |
|------|---------|
| `/root/.claude/ensure-ccd-bypass.sh` | Idempotent applier. Replaces each versioned binary in **both** dirs with a wrapper that, **for `stream-json` sessions only**, appends `--permission-mode bypassPermissions --dangerously-skip-permissions` (last flag wins) and exports `IS_SANDBOX=1`. Original preserved as `<version>.real`. Logs every wrapper invocation. |
| `claude-ccd-bypass.path` (systemd) | Watches **both** binary dirs; re-runs the applier the instant an update drops a new binary. |
| `claude-ccd-bypass.timer` (systemd) | 5-minute fallback poll. |
| `claude-ccd-bypass.service` (systemd) | The oneshot the `.path`/`.timer` trigger. |
| `/root/.claude/ensure-root-bypass.sh` | Supplementary: keeps `IS_SANDBOX=1` in `~/.claude/settings.json`, `/etc/environment`, and `~/.bashrc` for plain terminal `claude --dangerously-skip-permissions`. |

Non-`stream-json` calls (`claude update`, `claude mcp`, `claude doctor`, `--version`, the
interactive TUI) pass through **untouched** — they never get the flag and never hit the
flag's hard-exit.

### Diagnostics

Every wrapper invocation is logged to `/root/.claude/ccd-wrapper-invocations.log`:

```
2026-09-16T12:57:48Z bin=claude    inject=0 argc=1  args=--version
2026-09-16T12:57:48Z bin=2.1.271   inject=1 argc=10 args=--input-format stream-json --output-format stream-json ...
```

`inject=1` means the flag/mode were appended; `inject=0` means pass-through. If a root
session ever lands in Accept Edits again, this log shows which binary it used and whether a
wrapper was even hit (its absence there = a launch path not yet covered).

## Install

Run as **root** on the host where Claude Code runs:

```sh
sudo ./install.sh
```

> **Assumes root** (`~/.claude` = `/root/.claude`, native install under `/root/.local`).
> Paths are hardcoded to `/root`; adjust the scripts/units if your setup differs.

## Verify

The fix applies to **new** sessions — a running session keeps its mode. Start (or re-open)
a session; it should come up in Bypass Permissions. To check a binary directly:

```sh
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' \
  | /root/.local/share/claude/versions/"$(ls /root/.local/share/claude/versions | grep -E '^[0-9]' | grep -v '\.real$' | sort -V | tail -1)" \
    --input-format stream-json --output-format stream-json --verbose \
    --setting-sources=user,project,local --permission-mode acceptEdits --max-turns 1 2>/dev/null \
  | grep -o '"permissionMode":"[^"]*"' | head -1
# expect: "permissionMode":"bypassPermissions"
```

## Uninstall

```sh
sudo ./uninstall.sh
```

Disables/removes the units and restores every wrapped binary in both dirs from its `.real`
backup.

## Security note

Bypass Permissions disables Claude Code's permission prompts entirely. Only enable it on a
host you treat as a disposable sandbox (which is what `IS_SANDBOX=1` asserts). Do not run
this where an agent must not be able to act without approval.
