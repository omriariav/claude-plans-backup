---
name: claude-config-backup
description: Back up OR restore the user's entire Claude Code config (~/.claude/ settings, skills, commands, agents, hooks, global CLAUDE.md, keybindings, tmux config, optional Codex/Cursor/MCP configs). Backup mode creates one timestamped tarball with a generated RESTORE.md checklist and double-layer credential stripping (key-name AND value-pattern redaction). Restore mode (run on the new machine) re-registers plugin marketplaces, reinstalls plugins, merges MCP server defs into the new account's settings.json, restores hooks/agents/CLAUDE.md to their original paths, and reloads tmux. Built for migrating between accounts (e.g. personal $200 Max -> managed Enterprise). Use when the user asks to "back up claude", "backup claude", "save claude setup", "export claude config", "claude backup", "migrate claude account", "claude config dump", "restore claude config", "restore claude backup", "import claude config", or runs /claude-config-backup.
---

# claude-config-backup

One skill, two scripts. Back up on the old machine/account, restore on the new one.
Captures the three things a naïve backup silently drops (`CLAUDE.md`, `agents/`,
`hooks/`), adds value-based secret redaction, and defuses the `~/.claude.json`
clobber on restore.

## Mode 1: Backup

```bash
bash <repo>/skills/claude-config-backup/scripts/backup.sh [--dry-run] [--yes] [--out DIR]
```

Prints an inventory with sizes, asks Y/N for default-on and optional sections,
sanitizes `settings.json` + `~/.claude.json` (two layers — see below), generates
`RESTORE.md` + `MANIFEST.txt`, bundles a copy of `restore.sh`, then builds the
tarball at `<out>/claude-backup-YYYY-MM-DD-HHMM.tar.gz` (default out = `$HOME`).

Flags: `--dry-run` (plan only, no tarball) · `--yes` (accept all defaults) ·
`--out DIR` (write the tarball somewhere other than `$HOME`).

## Mode 2: Restore

After `tar xzf claude-backup-*.tar.gz -C ~/` on the new machine:

```bash
bash ~/restore-claude.sh           # PREVIEW by default — prints the plan, changes nothing
bash ~/restore-claude.sh --apply   # execute the plan (add --yes for no prompts)
```

(`restore-claude.sh` is unpacked to `$HOME` from the tarball, so the path exists
immediately.) **It previews by default** — the `claude` CLI / settings mutations
run only when you pass `--apply`, so you can read the full plan first. It:

1. Re-registers plugin marketplaces (`claude plugin marketplace add <url>`).
2. Reinstalls plugins (`claude plugin install <name>`).
3. Merges `mcpServers` defs into the new account's `~/.claude/settings.json`
   (backs the original up first — never clobbers managed Enterprise settings).
4. Re-applies `chmod +x` to restored hooks + tmux + skill scripts.
5. Lists MCP servers needing manual `/mcp` OAuth re-auth.

`~/.claude.json` wholesale-restore is **default OFF** (see "Restore safety").

Flags: `--apply` (execute; default is preview) · `--dry-run` (explicit preview) ·
`--yes` (accept all prompt defaults; pair with `--apply`).

## What gets backed up

**Always:**
- `~/.claude/settings.json` — sanitized (key-name + value-pattern), stored as `sanitized-settings.json` at archive root
- `~/.claude.json` — sanitized, stored as `sanitized-claude.json` at archive root
- `~/.claude/CLAUDE.md` — global personal instructions *(gap fixed vs original)*
- `~/.claude/skills/`, `~/.claude/commands/`, `~/.claude/agents/` *(agents gap fixed)*
- `~/.claude/hooks/` — custom hooks referenced by settings.json, e.g. `inject-time.sh` *(gap fixed; restore re-chmods them)*
- `~/.claude/keybindings.json`, `~/.claude/settings.local.json`
- `~/.tmux.conf`, `~/.tmux/scripts/`

**Default-on (declinable):**
- `~/.claude/projects/**/memory/` — auto-memory (persistent memory store; small)

**Opt-in (default off):**
- `~/.claude/projects/**/*.jsonl` — conversation transcripts (`claude --resume`
  history). Off by default: they are the bulk of the archive and resume only
  surfaces them when the new machine's working-directory paths match (see RESTORE.md).
- `~/.codex/config.toml`, `~/.cursor/mcp.json`, `~/.config/multi-sql-mcp/config.toml`

**Never included:**
- `~/.claude/.credentials.json` (account-tied — re-auth via `/login`)
- `~/.claude/plugins/cache/`, runtime state (`sessions/`, `telemetry/`, `daemon/`, `file-history/`, `history.jsonl`)

## Credential stripping (two layers)

The original skill stripped only by **key name** (`credential|token|secret|password|api[_-]?key`),
so a secret under a bland key name would leak. This version adds a **value-pattern**
pass that redacts any string matching `sk-ant-…`, `ghp_/gho_…`, `xox[bpoas]-…`,
`AKIA…`, JWTs (`eyJ….eyJ….…`), or PEM blocks (`-----BEGIN …`) — wherever they sit.
Both passes run recursively over `settings.json` and `~/.claude.json`.

> Hook scripts and skill files are archived **verbatim** (not scanned). If you ever
> hard-code a secret inside a hook/skill, it travels in the tarball — keep secrets in
> env/keychain, not in scripts.

## Restore safety

- **`~/.claude.json` wholesale-restore is default OFF.** That file carries the OLD
  account's `oauthAccount` identity (email + UUID), which the name/value sanitizer does
  not strip. Copying it over a freshly-logged-in Enterprise account can confuse the new
  identity. The restore only *merges `mcpServers`* by default. Say Y to the explicit
  prompt only if you understand the trade-off.
- The MCP merge backs up the existing `settings.json`/`.claude.json` to `*.bak.<ts>`
  before writing.
- Tokens are never restored — every OAuth MCP server (Atlassian, Gmail, Slack, etc.)
  must be reconnected via `/mcp`.

## Notes for Claude

- Interactive by default. When running on the user's behalf in-conversation, use
  `--yes` to avoid hanging on `read -rp`, then summarize the tarball path + size.
- If `jq` is missing the script aborts with an install hint — surface it immediately.
- The tarball contains transcripts/memory = confidential content even after
  sanitization. Tell the user to keep it on managed storage, not personal cloud.
- This repo's `.gitignore` excludes `*.tar.gz` so a backup is never accidentally
  committed. Don't override that.
- This is a snapshot tool, not a sync tool. Re-run for a fresh snapshot.
