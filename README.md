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
`.gitignore` blocks committing tarballs (which contain confidential transcripts).

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

Produces `~/claude-backup-YYYY-MM-DD-HHMM.tar.gz` containing a sanitized config,
`RESTORE.md`, `MANIFEST.txt`, and a bundled `restore-claude.sh`.

## Restore (new machine / Enterprise account)

```bash
# 1. install Claude Code, then: /login   (into the new account)
tar xzf claude-backup-*.tar.gz -C ~/
bash ~/restore-claude.sh --dry-run        # preview
bash ~/restore-claude.sh                  # apply
# then: /mcp to reconnect servers (OAuth re-auth — tokens are never backed up)
```

## What it never touches

`~/.claude/.credentials.json`, token/secret values, `plugins/cache/`, and runtime
state (`sessions/`, `telemetry/`, `daemon/`, `file-history/`, `history.jsonl`).

## Security notes

- The tarball holds transcripts + auto-memory = **confidential** content even after
  sanitization. Keep it on managed storage, not personal cloud.
- Hook/skill scripts are archived verbatim, not scanned. Keep secrets in env/keychain,
  never hard-coded in a script.
- An Enterprise account may push **managed settings**; restore only *merges mcpServers*
  rather than overwriting `settings.json`, so it won't fight org policy.
