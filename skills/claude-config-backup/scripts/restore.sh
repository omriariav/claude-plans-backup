#!/usr/bin/env bash
# Restore counterpart to backup.sh. Run on the NEW machine/account AFTER:
#   1. Claude Code installed + logged into the new account (/login)
#   2. tar xzf claude-backup-*.tar.gz -C ~/
#
# Files (CLAUDE.md, skills, commands, agents, hooks, tmux) already unpacked to their
# original paths by tar. This script handles the parts tar can't:
#   - re-register plugin marketplaces      (claude plugin marketplace add ...)
#   - reinstall plugins                    (claude plugin install ...)
#   - merge mcpServers into the new settings.json (original backed up first)
#   - re-chmod restored hook/skill/tmux scripts
#   - optionally restore ~/.claude.json wholesale  (DEFAULT OFF — see warning)
#
# Flags: --dry-run (change nothing) · --yes (accept defaults non-interactively)

set -uo pipefail

DRY_RUN=0
NONINTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  NONINTERACTIVE=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

ask_yn() {
  local prompt="$1" default="${2:-Y}" reply
  local hint="[Y/n]"; [ "$default" = "N" ] && hint="[y/N]"
  if [ "$NONINTERACTIVE" -eq 1 ]; then [ "$default" = "Y" ] && return 0 || return 1; fi
  read -rp "$prompt $hint " reply
  reply="${reply:-$default}"
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Run a command from explicit args (no eval — args are never re-parsed by the shell).
run() {
  echo "  + $*"
  [ "$DRY_RUN" -eq 0 ] && "$@"
}

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
if ! command -v claude >/dev/null; then
  [ "$DRY_RUN" -eq 0 ] && { echo "❌ claude CLI not on PATH — install Claude Code first" >&2; exit 1; }
  echo "⚠️  claude CLI not on PATH — dry-run only"
fi

SANITIZED="$HOME/sanitized-settings.json"
[ -f "$SANITIZED" ] || { echo "❌ $SANITIZED not found — run 'tar xzf claude-backup-*.tar.gz -C ~/' first" >&2; exit 1; }

CURRENT="$HOME/.claude/settings.json"
CLAUDEJSON_SANITIZED="$HOME/sanitized-claude.json"
CURRENT_CLAUDEJSON="$HOME/.claude.json"

echo ""
echo "🔁 Claude Config Restore (hardened)"
echo "==================================="
echo ""

# ── Marketplaces ──────────────────────────────────────────
echo "📚 Plugin marketplaces in backup:"
MARKETS=$(jq -r '.extraKnownMarketplaces // {} | to_entries[] | "\(.key)\t\(.value.source.url // .value.source.path // "?")"' "$SANITIZED")
[ -z "$MARKETS" ] && echo "  (none)" || while IFS=$'\t' read -r name url; do echo "  - $name → $url"; done <<< "$MARKETS"
echo ""
if [ -n "$MARKETS" ] && ask_yn "Re-register all marketplaces?" Y; then
  while IFS=$'\t' read -r name url; do
    [ -z "$url" ] || [ "$url" = "?" ] && continue
    run claude plugin marketplace add "$url"
  done <<< "$MARKETS"
fi
echo ""

# ── Plugins ───────────────────────────────────────────────
echo "🔌 Enabled plugins in backup:"
PLUGINS=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$SANITIZED")
[ -z "$PLUGINS" ] && echo "  (none)" || echo "$PLUGINS" | sed 's/^/  - /'
echo ""
if [ -n "$PLUGINS" ] && ask_yn "Install all plugins?" Y; then
  while IFS= read -r p; do [ -z "$p" ] && continue; run claude plugin install "$p"; done <<< "$PLUGINS"
fi
echo ""

# ── MCP servers (merge into settings.json) ────────────────
echo "🔗 MCP servers in backup (settings.json):"
MCPS_S=$(jq -r '.mcpServers // {} | keys[]' "$SANITIZED")
echo "${MCPS_S:-  (none)}" | sed 's/^/  - /'
if [ -f "$CLAUDEJSON_SANITIZED" ]; then
  echo ""; echo "🔗 MCP servers in backup (.claude.json — global + per-project):"
  { jq -r '.mcpServers // {} | keys[]' "$CLAUDEJSON_SANITIZED"
    jq -r '.projects // {} | .[] | .mcpServers // {} | keys[]' "$CLAUDEJSON_SANITIZED"; } | sort -u | sed 's/^/  - /'
fi
echo ""

if [ -n "$MCPS_S" ] && ask_yn "Merge mcpServers from backup into ~/.claude/settings.json?" Y; then
  mkdir -p "$HOME/.claude"
  if [ -f "$CURRENT" ]; then
    TMP=$(mktemp)
    jq -s '.[0].mcpServers = ((.[0].mcpServers // {}) * (.[1].mcpServers // {})) | .[0]' "$CURRENT" "$SANITIZED" > "$TMP"
    if [ "$DRY_RUN" -eq 0 ]; then
      cp "$CURRENT" "$CURRENT.bak.$(date +%s)"; mv "$TMP" "$CURRENT"
      echo "  ✓ Merged. Original → $CURRENT.bak.*"
    else
      rm -f "$TMP"; echo "  (dry run) would merge mcpServers into $CURRENT"
    fi
  else
    [ "$DRY_RUN" -eq 0 ] && { jq '{mcpServers: (.mcpServers // {})}' "$SANITIZED" > "$CURRENT"; echo "  ✓ Created $CURRENT with mcpServers"; } \
                         || echo "  (dry run) would create $CURRENT from backup mcpServers"
  fi
fi
echo ""

# ── ~/.claude.json wholesale restore — DEFAULT OFF ────────
if [ -f "$CLAUDEJSON_SANITIZED" ]; then
  echo "⚠️  ~/.claude.json wholesale-restore carries the OLD account's identity"
  echo "    (oauthAccount: email + UUID) onto this new login. Recommended: NO."
  if ask_yn "Overwrite ~/.claude.json with the backup anyway?" N; then
    [ -f "$CURRENT_CLAUDEJSON" ] && [ "$DRY_RUN" -eq 0 ] && cp "$CURRENT_CLAUDEJSON" "$CURRENT_CLAUDEJSON.bak.$(date +%s)"
    if [ "$DRY_RUN" -eq 0 ]; then cp "$CLAUDEJSON_SANITIZED" "$CURRENT_CLAUDEJSON"; echo "  ✓ Overwrote (prior file backed up)"; \
    else echo "  (dry run) would overwrite $CURRENT_CLAUDEJSON"; fi
  else
    echo "  Skipped (recommended)."
  fi
fi
echo ""
echo "⚠️  Run /mcp to reconnect each server — secrets were NOT restored."
echo "    OAuth servers prompt to authorize; token-based servers (env vars) need the token re-entered."
echo ""

# ── tmux reload ───────────────────────────────────────────
if [ -n "${TMUX:-}" ] && [ -f "$HOME/.tmux.conf" ]; then
  ask_yn "Reload tmux config now? (you're inside tmux)" Y && run tmux source-file "$HOME/.tmux.conf"
fi

# ── Re-chmod restored scripts (hooks especially) ──────────
if ask_yn "Re-apply executable bit on restored hooks / skills / tmux scripts?" Y; then
  [ -d "$HOME/.claude/hooks" ]   && run find "$HOME/.claude/hooks"   -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
  [ -d "$HOME/.claude/skills" ]  && run find "$HOME/.claude/skills"  -type f -name '*.sh' -exec chmod +x {} +
  [ -d "$HOME/.tmux/scripts" ]   && run find "$HOME/.tmux/scripts"   -type f -name '*.sh' -exec chmod +x {} +
fi

echo ""
echo "✅ Restore steps complete."
echo ""
echo "Manual follow-ups:"
echo "  - /mcp                 # reconnect each MCP server (OAuth)"
echo "  - claude plugin list   # confirm plugins installed"
echo "  - /setup-statusline    # if your statusline command was plugin-managed"
echo "  - rm ~/sanitized-*.json ~/RESTORE.md ~/MANIFEST.txt ~/restore-claude.sh   # cleanup"
