#!/usr/bin/env bash
# bin/install-copilot.sh - install the harness onto a work machine, for the
# GitHub Copilot target (Copilot CLI and Copilot in VS Code).
#
#   ./bin/install-copilot.sh --tier N [--dry-run] [--config-dir DIR]
#
# The Claude Code target has its own installer, bin/install.sh. The two write to
# different directories and can both be installed on the same machine.
#
# Tiers are cumulative:
#   0  core rule markdown only, as *.instructions.md files. Nothing executable.
#   1  + skills and the custom agent (markdown only, nothing executes).
#   2  + guard hooks, the hook wiring JSON, the settings template, and the
#         skill executable helpers.
#   3  + prints the MCP manifest, the plugin manifest, the two MCP example
#         files, and the VS Code settings snippet. Copies nothing extra: those
#         layers need network access, an organization policy decision, or a
#         hand merge into a settings file, so they stay manual on purpose.
# Default tier is 1.
#
# Reads manifest.copilot.txt and installs only what it lists. Anything already
# present at a destination is backed up to
# <config-dir>/harness-backup-<timestamp>/ before being overwritten, preserving
# its relative path.
#
# settings.json is never clobbered: if one already exists, the template is
# written next to it as settings.work.template.json and the merge instructions
# are printed. If none exists, the template is installed as settings.json.
#
# Portable: POSIX bash, no GNU-only flags, macOS and Linux.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO/manifest.copilot.txt"

# Shared path-safety helpers (harness_relpath_ok, harness_under).
[ -r "$REPO/bin/_lib.sh" ] || { echo "install-copilot: bin/_lib.sh missing, cannot validate paths safely" >&2; exit 2; }
. "$REPO/bin/_lib.sh"

TIER=1
DRY=0
CONFIG_DIR="${COPILOT_HOME:-$HOME/.copilot}"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) [ $# -ge 2 ] || { echo "install-copilot: --tier needs a value" >&2; exit 2; }
            TIER="$2"; shift 2 ;;
    --tier=*) TIER="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    --config-dir) [ $# -ge 2 ] || { echo "install-copilot: --config-dir needs a value" >&2; exit 2; }
                  CONFIG_DIR="$2"; shift 2 ;;
    --config-dir=*) CONFIG_DIR="${1#*=}"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "install-copilot: unknown argument: $1" >&2; usage 2 ;;
  esac
done

case "$TIER" in
  0|1|2|3) ;;
  *) echo "install-copilot: --tier must be 0, 1, 2 or 3 (got '$TIER')" >&2; exit 2 ;;
esac
[ -f "$MANIFEST" ] || { echo "install-copilot: manifest not found at $MANIFEST" >&2; exit 2; }

STAMP="$(date '+%Y%m%dT%H%M%S')"
BACKUP="$CONFIG_DIR/harness-backup-$STAMP"
backup_made=0

say()  { printf '%s\n' "$*"; }
act()  { if [ "$DRY" -eq 1 ]; then printf '  would %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

say "install-copilot: repo       $REPO"
say "install-copilot: config dir $CONFIG_DIR"
say "install-copilot: tier       $TIER$( [ "$DRY" -eq 1 ] && printf ' (dry run)' )"
say ""

# Back up one destination file, preserving its path under the backup dir.
backup_one() { # $1 = absolute destination path, $2 = relative label
  [ -e "$1" ] || return 0
  if [ "$DRY" -eq 1 ]; then
    act "back up existing $2 to harness-backup-$STAMP/$2"
    return 0
  fi
  mkdir -p "$BACKUP/$(dirname "$2")" || return 1
  cp -p "$1" "$BACKUP/$2" || return 1
  backup_made=1
}

# Copy a repo file to a destination, substituting the config-dir placeholders.
# Both placeholders are substituted with the SAME directory: files shared from
# the claude/ tree carry __CLAUDE_HOME__, files authored for this target carry
# __COPILOT_HOME__, and on this machine both mean the Copilot config dir.
install_one() { # $1 = repo-relative source, $2 = config-dir-relative dest
  # Never read outside the repo or write outside CONFIG_DIR, even if the
  # manifest is malformed or hostile.
  if ! harness_relpath_ok "$1" || ! harness_relpath_ok "$2"; then
    echo "  REFUSED unsafe manifest path: '$1' -> '$2'" >&2; return 1
  fi
  src="$REPO/$1"
  dst="$CONFIG_DIR/$2"
  if ! harness_under "$CONFIG_DIR" "$dst"; then
    echo "  REFUSED destination outside config dir: $2" >&2; return 1
  fi
  [ -f "$src" ] || { echo "  MISSING in repo: $1" >&2; return 1; }
  if ! backup_one "$dst" "$2"; then
    echo "  BACKUP FAILED for $2, skipping to avoid overwriting it" >&2; return 1
  fi
  if [ "$DRY" -eq 1 ]; then
    act "install $2"
    return 0
  fi
  mkdir -p "$(dirname "$dst")" || return 1
  # Escape CONFIG_DIR for the sed replacement side: backslash first, then the
  # delimiter and & so a path holding those characters cannot break the command.
  esc=$(printf '%s' "$CONFIG_DIR" | sed -e 's/\\/\\\\/g' -e 's/[&|]/\\&/g')
  if sed -e "s|__COPILOT_HOME__|$esc|g" -e "s|__CLAUDE_HOME__|$esc|g" "$src" > "$dst.harness-tmp" 2>/dev/null; then
    mv "$dst.harness-tmp" "$dst"
  else
    rm -f "$dst.harness-tmp"
    cp "$src" "$dst" || return 1
  fi
  # Only .sh gets the execute bit. The .ps1 twins deliberately do not need it:
  # they are invoked as `pwsh -NoProfile -File <path>`, which does not consult
  # the execute bit, and on Windows the bit has no meaning at all.
  case "$1" in
    *.sh) chmod +x "$dst" ;;
  esac
  act "installed $2"
}

installed=0
skipped_settings=0

while IFS='|' read -r kind tier repo_path live_path; do
  case "$kind" in ''|'#'*) continue ;; esac
  case "$tier" in ''|*[!0-9]*) continue ;; esac
  [ "$tier" -le "$TIER" ] || continue
  [ "$live_path" != "-" ] || continue

  # settings.json needs the never-clobber rule, so it is handled below.
  case "$repo_path" in
    copilot/settings.work.template.json) continue ;;
  esac

  install_one "$repo_path" "$live_path" && installed=$((installed + 1))
done < "$MANIFEST"

# --- the settings template (tier 2) -----------------------------------------
if [ "$TIER" -ge 2 ]; then
  say ""
  say "install-copilot: settings"
  dst="$CONFIG_DIR/settings.json"
  if [ -e "$dst" ]; then
    skipped_settings=1
    install_one "copilot/settings.work.template.json" "settings.work.template.json" >/dev/null
    act "wrote settings.work.template.json next to your existing settings.json"
    say ""
    say "  A settings.json already exists here, so it was NOT touched. Read the"
    say "  template and merge by hand if you want anything from it:"
    say ""
    say "    $CONFIG_DIR/settings.json"
    say "    $CONFIG_DIR/settings.work.template.json"
    say ""
    say "  The template sets nothing active on purpose, so in practice there is"
    say "  usually nothing to merge. Its value is the commented recipes: the"
    say "  --deny-tool one-liners, and the keys that are documented in prose"
    say "  only and therefore marked UNVERIFIED. Do NOT copy a model or any"
    say "  bypass mode out of it: it deliberately sets neither."
  else
    install_one "copilot/settings.work.template.json" "settings.json" && installed=$((installed + 1))
    say "  No settings.json existed, so the template was installed as one."
    say "  It is valid JSONC and sets nothing active; read its comments before"
    say "  adding anything."
  fi

  say ""
  say "install-copilot: hooks are wired in $CONFIG_DIR/hooks/harness-hooks.json,"
  say "  not in settings.json. Each entry carries a bash path AND a powershell"
  say "  path, so the same config drives the .sh guards on macOS/Linux and the"
  say "  .ps1 twins on Windows. The twins need PowerShell 7+ (pwsh) on PATH;"
  say "  Windows PowerShell 5.1 is NOT enough. Verify the install with:"
  say ""
  say "    HOOKS_DIR=$CONFIG_DIR/hooks bash copilot/hooks/tests/test-copilot-guards-smoke.sh"
  say ""
  say "  That suite runs every case against BOTH twins. It skips the PowerShell"
  say "  half if no pwsh is found; set PWSH_BIN to point at one."
  say ""
  say "  Hooks are a Preview feature and hook TIMEOUTS FAIL OPEN, so treat the"
  say "  guards as a safety net, not as a wall. The VS Code deny lists in"
  say "  copilot/vscode-settings.snippet.jsonc are the second line."
fi

# --- tier 3: manifests are documentation, not an install --------------------
if [ "$TIER" -ge 3 ]; then
  say ""
  say "install-copilot: tier 3 is a reading list, not an install step."
  say "  Nothing below is copied or enabled. MCP is disabled by default in"
  say "  GitHub organizations, so an administrator has to allowlist a server"
  say "  before any of it runs. Read these, ask IT the questions each one"
  say "  names, and install by hand only what comes back approved."
  say ""
  say "    $REPO/claude/mcp.manifest.md          what each server buys, and what breaks without it"
  say "    $REPO/claude/plugins.manifest.md      the plugin side of the same split"
  say "    $REPO/copilot/mcp/mcp.json.example    CLI and Agent Host shape (mcpServers key)"
  say "    $REPO/copilot/mcp/vscode-mcp.json.example   VS Code shape (servers key, incompatible)"
  say "    $REPO/copilot/vscode-settings.snippet.jsonc  VS Code settings to merge by hand"
fi

say ""
if [ "$DRY" -eq 1 ]; then
  say "install-copilot: dry run complete, nothing written."
else
  say "install-copilot: $installed file(s) installed."
  if [ "$backup_made" -eq 1 ]; then
    say "install-copilot: previous versions backed up to $BACKUP"
  fi
  if [ "$skipped_settings" -eq 1 ]; then
    say "install-copilot: settings.json left alone, see the merge steps above."
  fi
  if [ "$TIER" -ge 1 ]; then
    say ""
    say "First run: check what this machine actually allows before assuming."
    say "  copilot            then /env, /model, /agent"
    say "  copilot plugins list --json"
    say "Organization policy can pin models, deny MCP, and force its own hooks,"
    say "and those settings win over everything installed here."
  fi
fi
exit 0
