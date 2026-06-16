#!/usr/bin/env bash
# Interactive backup of Claude Code config + related dotfiles.
#
# Hardened fork: captures CLAUDE.md / agents / hooks / settings.local.json that the
# original skill silently dropped, and sanitizes by BOTH key-name and value-pattern.
#
# Usage:
#   backup.sh [--dry-run] [--yes] [--out DIR]
#
# --dry-run  : show inventory + plan; create no tarball
# --yes      : accept all defaults non-interactively (good for re-runs / automation)
# --out DIR  : write the tarball into DIR instead of $HOME

set -uo pipefail

DRY_RUN=0
NONINTERACTIVE=0
OUT_DIR="$HOME"
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  arg="${args[$i]}"
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  NONINTERACTIVE=1 ;;
    --out)     i=$((i+1)); OUT_DIR="${args[$i]:-$HOME}" ;;
    --out=*)   OUT_DIR="${arg#--out=}" ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
  i=$((i+1))
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ────────────────────────────────────────────────
size_of() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
size_b()  { du -sk "$1" 2>/dev/null | awk '{print $1*1024}'; }
human()   {
  numfmt --to=iec --suffix=B "$1" 2>/dev/null && return
  awk -v b="$1" 'BEGIN{u="B KB MB GB TB"; split(u,a," "); i=1;
    while(b>=1024 && i<5){b/=1024;i++} printf (i==1?"%d%s\n":"%.1f%s\n"), b, a[i]}'
}
print_kv() { printf "  %-46s %10s  %s\n" "$1" "$2" "$3"; }

ask_yn() {
  local prompt="$1" default="${2:-Y}" reply
  local hint="[Y/n]"; [ "$default" = "N" ] && hint="[y/N]"
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    [ "$default" = "Y" ] && return 0 || return 1
  fi
  read -rp "$prompt $hint " reply
  reply="${reply:-$default}"
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

command -v jq  >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar is required" >&2; exit 1; }

# ── Every backupable item: tier|path|description ──────────
# Tier: always | default-on | optional
ITEMS=(
  "always|$HOME/.claude/settings.json|Claude Code settings (sanitized)"
  "always|$HOME/.claude.json|Per-project state + MCP servers (sanitized)"
  "always|$HOME/.claude/CLAUDE.md|Global personal instructions"
  "always|$HOME/.claude/skills|Custom skills"
  "always|$HOME/.claude/commands|Custom slash commands"
  "always|$HOME/.claude/agents|Custom agents"
  "always|$HOME/.claude/hooks|Custom hooks (inject-time.sh, validators)"
  "always|$HOME/.claude/keybindings.json|Custom keybindings"
  "always|$HOME/.claude/settings.local.json|Local settings overrides"
  "always|$HOME/.tmux.conf|Tmux config"
  "always|$HOME/.tmux/scripts|Tmux custom scripts"
  "default-on|$HOME/.claude/projects|Auto-memory + conversation transcripts"
  "optional|$HOME/.codex/config.toml|Codex CLI config (MCP plugin defaults)"
  "optional|$HOME/.cursor/mcp.json|Cursor MCP server config"
  "optional|$HOME/.config/multi-sql-mcp/config.toml|multi-sql-mcp DB connections"
)

echo ""
echo "🔒 Claude Config Backup (hardened)"
echo "=================================="
echo ""
echo "📦 Inventory:"
echo ""

ALWAYS_PATHS=()
DEFAULT_PATHS=()
OPTIONAL_PATHS=()

for tuple in "${ITEMS[@]}"; do
  IFS='|' read -r tier path desc <<< "$tuple"
  if [ ! -e "$path" ]; then
    print_kv "${path/$HOME/~}" "(missing)" "$desc — skipped"
    continue
  fi
  [ -L "$path" ] && desc="$desc ⚠symlink"
  s=$(size_of "$path")
  case "$tier" in
    always)      print_kv "${path/$HOME/~}" "$s" "✓ $desc";  ALWAYS_PATHS+=("$path") ;;
    default-on)  print_kv "${path/$HOME/~}" "$s" "? $desc (default ON)";  DEFAULT_PATHS+=("$path:$desc") ;;
    optional)    print_kv "${path/$HOME/~}" "$s" "? $desc (default OFF)"; OPTIONAL_PATHS+=("$path:$desc") ;;
  esac
done
echo ""

# ── Per-item Y/N for default-on & optional ────────────────
# Guarded against bash 3.2 (macOS /bin/bash), where `"${arr[@]}"` on an empty
# array under `set -u` aborts with "unbound variable".
INCLUDE_PATHS=("${ALWAYS_PATHS[@]+"${ALWAYS_PATHS[@]}"}")

for entry in "${DEFAULT_PATHS[@]+"${DEFAULT_PATHS[@]}"}"; do
  IFS=':' read -r path desc <<< "$entry"
  if [ "$path" = "$HOME/.claude/projects" ]; then
    ask_yn "Include conversation transcripts (claude --resume history)?" Y && INCLUDE_TRANSCRIPTS=1 || INCLUDE_TRANSCRIPTS=0
    ask_yn "Include auto-memory (persistent memory files)?" Y          && INCLUDE_MEMORY=1      || INCLUDE_MEMORY=0
    continue
  fi
  ask_yn "Include $desc?" Y && INCLUDE_PATHS+=("$path")
done

for entry in "${OPTIONAL_PATHS[@]+"${OPTIONAL_PATHS[@]}"}"; do
  IFS=':' read -r path desc <<< "$entry"
  ask_yn "Include $desc?" N && INCLUDE_PATHS+=("$path")
done

INCLUDE_TRANSCRIPTS="${INCLUDE_TRANSCRIPTS:-0}"
INCLUDE_MEMORY="${INCLUDE_MEMORY:-0}"

# ── Staging + file list ───────────────────────────────────
STAGING=$(mktemp -d "/tmp/claude-backup.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
FILELIST="$STAGING/files.txt"
: > "$FILELIST"

for p in "${INCLUDE_PATHS[@]+"${INCLUDE_PATHS[@]}"}"; do
  [ -e "$p" ] && echo "$p" >> "$FILELIST"
done

# projects/ handled granularly
if [ "$INCLUDE_TRANSCRIPTS" -eq 1 ] && [ "$INCLUDE_MEMORY" -eq 1 ]; then
  echo "$HOME/.claude/projects" >> "$FILELIST"
elif [ "$INCLUDE_TRANSCRIPTS" -eq 1 ]; then
  find "$HOME/.claude/projects" -name "*.jsonl" 2>/dev/null >> "$FILELIST"
elif [ "$INCLUDE_MEMORY" -eq 1 ]; then
  find "$HOME/.claude/projects" -type d -name "memory" 2>/dev/null >> "$FILELIST"
fi

# ── Sanitize JSON: layer 1 (key names) + layer 2 (value patterns) ──
SCRUB_JQ='
def secretish:
  test("sk-ant-|ghp_|gho_|github_pat_|xox[bpoas]-|AKIA[0-9A-Z]{16}|-----BEGIN|eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}");
def scrub:
  if   type == "object" then
         with_entries(
           select(.key | test("credential|token|secret|password|api[_-]?key"; "i") | not)
           | .value |= scrub)
  elif type == "array"  then map(scrub)
  elif type == "string" then (if secretish then "REDACTED" else . end)
  else . end;
scrub'

SETTINGS_SRC="$HOME/.claude/settings.json"
SETTINGS_OUT="$STAGING/sanitized-settings.json"
if [ -f "$SETTINGS_SRC" ]; then
  jq "$SCRUB_JQ" "$SETTINGS_SRC" > "$SETTINGS_OUT"
  grep -v "/.claude/settings.json$" "$FILELIST" > "$FILELIST.tmp" || true; mv "$FILELIST.tmp" "$FILELIST"
fi

CLAUDEJSON_SRC="$HOME/.claude.json"
CLAUDEJSON_OUT="$STAGING/sanitized-claude.json"
if [ -f "$CLAUDEJSON_SRC" ]; then
  jq "$SCRUB_JQ" "$CLAUDEJSON_SRC" > "$CLAUDEJSON_OUT"
  grep -v "/.claude.json$" "$FILELIST" > "$FILELIST.tmp" || true; mv "$FILELIST.tmp" "$FILELIST"
fi

# ── RESTORE.md ────────────────────────────────────────────
RESTORE="$STAGING/RESTORE.md"
cat > "$RESTORE" <<'RESTORE_HEADER'
# Restore Claude Code Config

This tarball contains your Claude Code config + dotfiles, sanitized of credentials
(key-name AND value-pattern). No tokens included — re-auth via /login and /mcp.

## Step 1 — Install Claude Code on the new machine, then log into the NEW account
```bash
# install per Anthropic's steps for your platform, then:
/login
```

## Step 2 — Unpack
```bash
tar xzf claude-backup-*.tar.gz -C ~/
# Files (CLAUDE.md, skills, commands, agents, hooks, tmux) land in their original paths.
# The sanitized JSONs land at ~/sanitized-settings.json and ~/sanitized-claude.json.
```

## Step 3 — Run the restore helper (re-adds marketplaces, plugins, merges MCP)
```bash
bash ~/restore-claude.sh        # add --dry-run first to preview
```

## Step 4 — settings.json
Your settings were NOT auto-overwritten (a managed Enterprise account may push its own).
Review ~/sanitized-settings.json and merge what you want by hand, OR let restore-claude.sh
merge just the mcpServers block.

RESTORE_HEADER

if [ -f "$SETTINGS_SRC" ]; then
  echo "## Plugin marketplaces to re-add" >> "$RESTORE"
  echo '```bash' >> "$RESTORE"
  jq -r '.extraKnownMarketplaces // {} | to_entries[] | "claude plugin marketplace add \(.value.source.url // .value.source.path)  # \(.key)"' "$SETTINGS_SRC" >> "$RESTORE" 2>/dev/null || true
  echo '```' >> "$RESTORE"
  echo "" >> "$RESTORE"
  echo "## Plugins to reinstall" >> "$RESTORE"
  echo '```bash' >> "$RESTORE"
  jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | "claude plugin install \(.key)"' "$SETTINGS_SRC" >> "$RESTORE" 2>/dev/null || true
  echo '```' >> "$RESTORE"
  echo "" >> "$RESTORE"
fi

cat >> "$RESTORE" <<'MCP_HEADER'
## MCP servers needing /mcp re-auth
Run `/mcp` and reconnect each (OAuth prompts for Atlassian, Gmail, Slack, etc.):

MCP_HEADER
{
  [ -f "$SETTINGS_SRC"   ] && jq -r '.mcpServers // {} | keys[]' "$SETTINGS_SRC"   2>/dev/null
  [ -f "$CLAUDEJSON_SRC" ] && jq -r '.mcpServers // {} | keys[]' "$CLAUDEJSON_SRC" 2>/dev/null
  [ -f "$CLAUDEJSON_SRC" ] && jq -r '.projects // {} | .[] | .mcpServers // {} | keys[]' "$CLAUDEJSON_SRC" 2>/dev/null
} | sort -u | sed 's/^/- `/; s/$/`/' >> "$RESTORE" 2>/dev/null || true

cat >> "$RESTORE" <<'TAIL'

## Reload tmux
```bash
tmux source-file ~/.tmux.conf
```

## NOT included (by design)
- `~/.claude/.credentials.json` + any token/secret values — re-auth via /login and /mcp
- `~/.claude/plugins/cache/` — regenerated on plugin install
- runtime state (sessions/, telemetry/, daemon/, file-history/, history.jsonl)
TAIL

# ── MANIFEST.txt ──────────────────────────────────────────
MANIFEST="$STAGING/MANIFEST.txt"
{
  echo "# Claude Config Backup Manifest"
  echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  echo "## Sanitized at archive root"
  echo "  sanitized-settings.json   (from ~/.claude/settings.json)"
  echo "  sanitized-claude.json     (from ~/.claude.json)"
  echo ""
  echo "## Files (unpack to original paths)"
  while IFS= read -r p; do echo "  ${p/$HOME/~}"; done < "$FILELIST"
} > "$MANIFEST"

# Bundle the restore helper at archive root
cp "$SCRIPT_DIR/restore.sh" "$STAGING/restore-claude.sh" 2>/dev/null || \
  echo "⚠️  restore.sh not found next to backup.sh — tarball will lack the helper" >&2

# ── Plan summary ──────────────────────────────────────────
TOTAL_BYTES=0
while IFS= read -r p; do b=$(size_b "$p" 2>/dev/null || echo 0); TOTAL_BYTES=$((TOTAL_BYTES + b)); done < "$FILELIST"
SETTINGS_BYTES=$(wc -c < "$SETTINGS_OUT" 2>/dev/null || echo 0)
CLAUDEJSON_BYTES=$(wc -c < "$CLAUDEJSON_OUT" 2>/dev/null || echo 0)
TOTAL_BYTES=$((TOTAL_BYTES + SETTINGS_BYTES + CLAUDEJSON_BYTES))

echo ""
echo "📋 Plan summary"
echo "----------------"
echo "  Paths to include:       $(wc -l < "$FILELIST" | tr -d ' ')"
echo "  Approx size:            $(human $TOTAL_BYTES)"
echo "  Sanitized settings:     $(human $SETTINGS_BYTES)"
echo "  Sanitized .claude.json: $(human $CLAUDEJSON_BYTES)"
echo "  + RESTORE.md, MANIFEST.txt, restore-claude.sh"
echo "  Output dir:             ${OUT_DIR/$HOME/~}"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "🟡 DRY RUN — no tarball created."
  echo ""; echo "Manifest preview:"; sed 's/^/  /' "$MANIFEST" | head -40
  echo ""; echo "RESTORE.md preview (first 30 lines):"; sed 's/^/  /' "$RESTORE" | head -30
  exit 0
fi

# ── Build tarball ─────────────────────────────────────────
mkdir -p "$OUT_DIR"
TS=$(date '+%Y-%m-%d-%H%M')
OUT="$OUT_DIR/claude-backup-$TS.tar.gz"
echo "📦 Building tarball at $OUT ..."

STAGING_FILES=(RESTORE.md MANIFEST.txt)
[ -f "$STAGING/restore-claude.sh"       ] && STAGING_FILES+=(restore-claude.sh)
[ -f "$SETTINGS_OUT"   ] && STAGING_FILES+=(sanitized-settings.json)
[ -f "$CLAUDEJSON_OUT" ] && STAGING_FILES+=(sanitized-claude.json)

# Store members $HOME-relative so the tarball restores via `tar xzf -C ~/`.
# (We deliberately avoid `-T filelist`: bsdtar/libarchive parses -T as a file
#  operand once operands have started, producing a broken archive. Explicit
#  operands after a single `-C "$HOME"` work on both bsdtar and GNU tar.)
HOME_OPERANDS=()
SKIPPED_NONHOME=()
while IFS= read -r p; do
  [ -z "$p" ] && continue
  case "$p" in
    "$HOME"/*) HOME_OPERANDS+=("${p#"$HOME"/}") ;;
    *)         SKIPPED_NONHOME+=("$p") ;;
  esac
done < "$FILELIST"

if [ "${#SKIPPED_NONHOME[@]}" -gt 0 ]; then
  echo "⚠️  Skipped (outside \$HOME — cannot store home-relative):" >&2
  printf '    %s\n' "${SKIPPED_NONHOME[@]}" >&2
fi
if [ "${#HOME_OPERANDS[@]}" -eq 0 ]; then
  echo "❌ Nothing under \$HOME to archive — aborting." >&2; exit 1
fi

tar czf "$OUT" \
  -C "$STAGING" "${STAGING_FILES[@]}" \
  -C "$HOME" "${HOME_OPERANDS[@]}"

SIZE=$(du -sh "$OUT" 2>/dev/null | awk '{print $1}')
echo ""
echo "✅ Backup complete!"
echo "  📁 $OUT"
echo "  📏 $SIZE"
echo ""
echo "Restore on the new machine:"
echo "  tar xzf $(basename "$OUT") -C ~/  &&  bash ~/restore-claude.sh --dry-run"
echo ""
echo "💡 Contains transcripts/memory = confidential. Keep on managed storage, not personal cloud."
