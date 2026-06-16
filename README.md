# claude-plans-backup

A hardened Claude Code config backup/restore skill. Built to migrate a Claude Code
setup between accounts/machines — e.g. a personal **$200 Max** plan → a managed
**Enterprise** account — without losing customizations.

It avoids the usual pitfalls of a naïve `tar` of `~/.claude`:

| Property | Naïve backup | This skill |
|----------|--------------|------------|
| `~/.claude/CLAUDE.md`, `~/.claude/agents/`, `~/.claude/hooks/` | silently dropped | backed up (hooks re-chmod'd on restore) |
| Credential stripping | key-name only | key-name **+ value-pattern** (`sk-ant-`, JWTs, `ghp_`, `AKIA`, PEM, …) |
| `~/.claude.json` restore | wholesale copy, default ON (clobbers new account identity) | **default OFF**, with warning |

Also: `restore.sh` runs commands from explicit args (no `eval`), and the repo
`.gitignore` blocks committing tarballs (which hold confidential config/memory, and
transcripts if you opt in).

## Install (make it an active skill)

```bash
ln -s "$PWD/skills/claude-config-backup" ~/.claude/skills/claude-config-backup
```

Then invoke in Claude Code with `/claude-config-backup`, or just run the scripts directly.

## Back up (old machine / current account)

```bash
bash skills/claude-config-backup/scripts/backup.sh --dry-run   # preview inventory
bash skills/claude-config-backup/scripts/backup.sh             # build tarball in $HOME
# options: --yes (no prompts), --out DIR (write elsewhere)
```

Produces `~/claude-backup-YYYY-MM-DD-HHMM.tar.gz` (mode `0600`) containing a
sanitized config, `RESTORE.md`, `MANIFEST.txt`, and a bundled `restore-claude.sh`.

By default the archive includes your settings, skills, commands, agents, hooks,
`CLAUDE.md`, and **auto-memory** — but **not conversation transcripts**, which are
opt-in (the prompt defaults to *no*; `--yes` skips them). They are the bulk of the
data and rarely needed on the new machine — see below.

## Restore (new machine / Enterprise account)

```bash
# 1. install Claude Code, then: /login   (into the new account)
tar xzf claude-backup-*.tar.gz -C ~/
bash ~/restore-claude.sh --dry-run        # preview
bash ~/restore-claude.sh                  # apply
# then: /mcp to reconnect servers (OAuth re-auth — tokens are never backed up)
```

## How `claude --resume` works (and why transcripts are opt-in)

Each Claude Code session is stored locally as a `.jsonl` file (the full message +
tool-call history) under:

```
~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
```

The subdirectory name is your **working directory** with `/` and `.` replaced by `-`
(e.g. `/Users/omri.a/Code/os-omri-pm` → `-Users-omri-a-Code-os-omri-pm`). `claude
--resume` lists the sessions for your *current* directory's encoded folder and replays
the chosen one back into a fresh session. It is **purely local and file-based** — no
server or account state is involved.

Two consequences for migration:

1. **Resume is account-independent.** Switching plans/accounts (e.g. Max → Enterprise)
   changes auth/billing, not your transcripts. On the same machine, resume works
   regardless of which account you're logged into.
2. **Resume is path-dependent.** It keys off the encoded working directory. On a new
   machine, restored transcripts only surface under `--resume` if you stand in a
   directory whose path matches the original (same username + same repo paths →
   works). If paths differ, the `.jsonl` files restore fine but won't be listed —
   the history isn't lost, just not one-click resumable (the files are plain JSON).

**So transcripts are off by default:** they're large (often gigabytes), and resume
continuity only pays off when the new machine keeps the same paths. Include them
(answer *yes* at the prompt) when you want full `--resume` history *and* the target
machine will use the same username and repo locations.

## What it never touches

`~/.claude/.credentials.json`, token/secret values, `plugins/cache/`, and runtime
state (`sessions/`, `telemetry/`, `daemon/`, `file-history/`, `history.jsonl`).

## Security notes

- The tarball is written `0600` and holds auto-memory (and transcripts, if you opt
  in) = **confidential** content even after sanitization. Keep it on managed storage,
  not personal cloud.
- Hook/skill scripts are archived verbatim, not scanned. Keep secrets in env/keychain,
  never hard-coded in a script.
- An Enterprise account may push **managed settings**; restore only *merges mcpServers*
  rather than overwriting `settings.json`, so it won't fight org policy.
