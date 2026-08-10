#!/usr/bin/env bash
# bin/install.sh - install the harness onto a work machine.
#
#   ./bin/install.sh --tier N [--dry-run] [--config-dir DIR]
#
# Tiers are cumulative:
#   0  core rule markdown only. Nothing executable, nothing wired.
#   1  + skills and agents.
#   2  + guard hooks and the settings template.
#   3  + prints the MCP and plugin manifests. Copies nothing extra: those two
#         layers need network access and a policy decision, so they stay
#         manual on purpose.
# Default tier is 1.
#
# Reads manifest.txt and installs only what it lists. Anything already present
# at a destination is backed up to <config-dir>/harness-backup-<timestamp>/
# before being overwritten, preserving its relative path.
#
# settings.json is never clobbered: if one already exists, the substituted
# template is written next to it as settings.work.template.json and the merge
# instructions are printed. If none exists, the template is installed as
# settings.json directly.
#
# Portable: POSIX bash, no GNU-only flags, macOS and Linux.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO/manifest.txt"

# Shared path-safety helpers (harness_relpath_ok, harness_under).
[ -r "$REPO/bin/_lib.sh" ] || { echo "install: bin/_lib.sh missing, cannot validate paths safely" >&2; exit 2; }
. "$REPO/bin/_lib.sh"

TIER=1
DRY=0
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) [ $# -ge 2 ] || { echo "install: --tier needs a value" >&2; exit 2; }
            TIER="$2"; shift 2 ;;
    --tier=*) TIER="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    --config-dir) [ $# -ge 2 ] || { echo "install: --config-dir needs a value" >&2; exit 2; }
                  CONFIG_DIR="$2"; shift 2 ;;
    --config-dir=*) CONFIG_DIR="${1#*=}"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "install: unknown argument: $1" >&2; usage 2 ;;
  esac
done

case "$TIER" in
  0|1|2|3) ;;
  *) echo "install: --tier must be 0, 1, 2 or 3 (got '$TIER')" >&2; exit 2 ;;
esac
[ -f "$MANIFEST" ] || { echo "install: manifest not found at $MANIFEST" >&2; exit 2; }

STAMP="$(date '+%Y%m%dT%H%M%S')"
BACKUP="$CONFIG_DIR/harness-backup-$STAMP"
backup_made=0

say()  { printf '%s\n' "$*"; }
act()  { if [ "$DRY" -eq 1 ]; then printf '  would %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

say "install: repo       $REPO"
say "install: config dir $CONFIG_DIR"
say "install: tier       $TIER$( [ "$DRY" -eq 1 ] && printf ' (dry run)' )"
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

# Copy a repo file to a destination, substituting the config-dir placeholder.
# Every installed text file gets the substitution, not just the settings
# template: skill and agent markdown reference installed paths too.
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
  if sed "s|__CLAUDE_HOME__|$esc|g" "$src" > "$dst.harness-tmp" 2>/dev/null; then
    mv "$dst.harness-tmp" "$dst"
  else
    rm -f "$dst.harness-tmp"
    cp "$src" "$dst" || return 1
  fi
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
    claude/settings.work.template.json) continue ;;
  esac

  install_one "$repo_path" "$live_path" && installed=$((installed + 1))
done < "$MANIFEST"

# --- the settings template (tier 2) -----------------------------------------
if [ "$TIER" -ge 2 ]; then
  say ""
  say "install: settings"
  dst="$CONFIG_DIR/settings.json"
  if [ -e "$dst" ]; then
    skipped_settings=1
    install_one "claude/settings.work.template.json" "settings.work.template.json" >/dev/null
    act "wrote settings.work.template.json next to your existing settings.json"
    say ""
    say "  A settings.json already exists here, so it was NOT touched. Merge by hand:"
    say ""
    say "    1. Open both files:"
    say "         $CONFIG_DIR/settings.json"
    say "         $CONFIG_DIR/settings.work.template.json"
    say "    2. Copy the whole \"hooks\" block across. If you already have hooks,"
    say "       append the entries rather than replacing the block: each matcher"
    say "       key holds an array and duplicates fire twice."
    say "    3. Merge \"permissions.deny\". These are portable hygiene rules and"
    say "       are safe to union with whatever you already deny."
    say "    4. Copy the \"env\" entry if you do not already set it."
    say "    5. Do NOT copy a defaultMode, a model, or a fallbackModel from the"
    say "       template: it deliberately sets none, so this machine keeps"
    say "       prompting for permission and keeps whatever model the account"
    say "       gives you."
    say "    6. Validate before you rely on it:"
    say "         jq empty $CONFIG_DIR/settings.json"
  else
    install_one "claude/settings.work.template.json" "settings.json" && installed=$((installed + 1))
    say "  No settings.json existed, so the template was installed as one."
    say "  Hook paths were rewritten to $CONFIG_DIR."
  fi
fi

# --- tier 3: manifests are documentation, not an install --------------------
if [ "$TIER" -ge 3 ]; then
  say ""
  say "install: tier 3 is a reading list, not an install step."
  say "  Nothing below is copied or enabled. Read both, ask IT the questions"
  say "  each one names, and install by hand only what comes back approved."
  say ""
  say "    $REPO/claude/mcp.manifest.md"
  say "    $REPO/claude/plugins.manifest.md"
fi

say ""
if [ "$DRY" -eq 1 ]; then
  say "install: dry run complete, nothing written."
else
  say "install: $installed file(s) installed."
  if [ "$backup_made" -eq 1 ]; then
    say "install: previous versions backed up to $BACKUP"
  fi
  if [ "$skipped_settings" -eq 1 ]; then
    say "install: settings.json left alone, see the merge steps above."
  fi
  if [ "$TIER" -ge 1 ]; then
    say ""
    say "Next: the context loop is NOT in this repo. Install the public warmstart"
    say "plugin (github.com/thiagoamaro91/warmstart) if you want it."
  fi
fi
exit 0
