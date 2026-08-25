#!/usr/bin/env bash
# bin/install.sh - install the harness onto a work machine.
#
#   ./bin/install.sh --tier N [--dry-run] [--config-dir DIR]
#                    [--windows | --no-windows]
#
# Tiers are cumulative:
#   0  core rule markdown only. Nothing executable, nothing wired.
#   1  + skills and agents (markdown only, nothing executes).
#   2  + guard hooks, the settings template, and skill executable helpers.
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
# WINDOWS. Tiers 0, 1 and 3 are markdown and need nothing special. Tier 2 does:
# the POSIX template wires each guard as a bare .sh path, and which shell the
# agent spawns a hook command through on Windows is undocumented, so a guard
# wired that way may silently never fire. With --windows, tier 2 additionally
# installs the PowerShell 7 twins (the manifest's authored-win rows) and uses
# claude/settings.work.windows.template.json, which invokes each guard as
# pwsh -NoProfile -File "<config-dir>/hooks/<name>.ps1", script path quoted so
# a profile directory with a space in it cannot split it. The .sh guards are
# installed too: they are harmless, and Git Bash may well run them.
#
# --windows is auto-detected from $OS=Windows_NT or from a MINGW/MSYS/CYGWIN
# uname (Git Bash), and the script prints which signal triggered it. Pass
# --windows to force it on, --no-windows to force it off. It needs PowerShell 7
# or newer (pwsh) on PATH; Windows PowerShell 5.1 is a different product and is
# NOT enough. The installer checks and prints the version it finds.
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
WINDOWS=auto
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) [ $# -ge 2 ] || { echo "install: --tier needs a value" >&2; exit 2; }
            TIER="$2"; shift 2 ;;
    --tier=*) TIER="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    --windows) WINDOWS=1; shift ;;
    --no-windows) WINDOWS=0; shift ;;
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

# --- Windows mode -----------------------------------------------------------
# Explicit flags win. Otherwise sniff, and always say which signal decided it:
# a silent auto-detect that guesses wrong is exactly how a guard ends up wired
# to a script nothing on the machine will run.
WIN_WHY=""
case "$WINDOWS" in
  1) WIN_WHY="--windows was passed" ;;
  0) WIN_WHY="--no-windows was passed" ;;
  *)
    UNAME_S=$(uname -s 2>/dev/null || echo unknown)
    if [ "${OS:-}" = "Windows_NT" ]; then
      WINDOWS=1; WIN_WHY="\$OS is Windows_NT"
    else
      case "$UNAME_S" in
        MINGW*|MSYS*|CYGWIN*)
          WINDOWS=1
          if [ -n "${USERPROFILE:-}" ]; then
            WIN_WHY="uname -s is $UNAME_S and \$USERPROFILE is set"
          else
            WIN_WHY="uname -s is $UNAME_S"
          fi ;;
        *) WINDOWS=0; WIN_WHY="uname -s is $UNAME_S, no Windows signal" ;;
      esac
    fi ;;
esac

# The settings template is per-platform; everything else is shared.
if [ "$WINDOWS" -eq 1 ]; then
  SETTINGS_SRC="claude/settings.work.windows.template.json"
else
  SETTINGS_SRC="claude/settings.work.template.json"
fi

STAMP="$(date '+%Y%m%dT%H%M%S')"
BACKUP="$CONFIG_DIR/harness-backup-$STAMP"
backup_made=0

say()  { printf '%s\n' "$*"; }
act()  { if [ "$DRY" -eq 1 ]; then printf '  would %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

say "install: repo       $REPO"
say "install: config dir $CONFIG_DIR"
say "install: tier       $TIER$( [ "$DRY" -eq 1 ] && printf ' (dry run)' )"
if [ "$WINDOWS" -eq 1 ]; then
  say "install: windows    ON  ($WIN_WHY)"
  say "install: template   $SETTINGS_SRC"
else
  say "install: windows    off ($WIN_WHY)"
fi
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
skipped_win=0

while IFS='|' read -r kind tier repo_path live_path; do
  case "$kind" in ''|'#'*) continue ;; esac
  case "$tier" in ''|*[!0-9]*) continue ;; esac
  [ "$tier" -le "$TIER" ] || continue
  [ "$live_path" != "-" ] || continue

  # authored-win rows are the Windows-only PowerShell twins. See the kind
  # documentation at the top of manifest.txt.
  case "$kind" in
    authored-win)
      if [ "$WINDOWS" -ne 1 ]; then
        skipped_win=$((skipped_win + 1))
        continue
      fi ;;
  esac

  # settings.json needs the never-clobber rule, so both templates are handled
  # below rather than as plain rows.
  case "$repo_path" in
    claude/settings.work.template.json|claude/settings.work.windows.template.json) continue ;;
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
    install_one "$SETTINGS_SRC" "settings.work.template.json" >/dev/null
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
    install_one "$SETTINGS_SRC" "settings.json" && installed=$((installed + 1))
    say "  No settings.json existed, so the template was installed as one."
    say "  Hook paths were rewritten to $CONFIG_DIR."
  fi

  # --- Windows: the guards only fire if PowerShell 7 is actually there -------
  if [ "$WINDOWS" -eq 1 ]; then
    say ""
    say "install: windows tier 2"
    say "  The four guards are wired as:"
    say "      pwsh -NoProfile -File \"$CONFIG_DIR/hooks/<name>.ps1\""
    say "  The quotes are deliberate: a profile directory with a space in it"
    say "  would otherwise split the argument and the guard would never fire."
    say "  Forward slashes are deliberate too. Under Git Bash __CLAUDE_HOME__ is"
    say "  substituted with a path like C:/Users/<you>/.claude, which pwsh"
    say "  accepts and which needs no JSON backslash escaping."
    say "  The .sh guards are installed alongside the twins and are harmless."
    say "  There is no PowerShell twin of log-skill-fire, so the Windows"
    say "  template carries no PostToolUse block. That hook only writes a log."
    if command -v pwsh >/dev/null 2>&1; then
      psver=$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null)
      if [ -n "$psver" ]; then
        say "  pwsh found on PATH, version $psver"
        case "$psver" in
          7.*|8.*|9.*|1[0-9].*) ;;
          *) say "  WARNING: that is not PowerShell 7 or newer. The twins need 7+." ;;
        esac
      else
        say "  WARNING: pwsh is on PATH but did not report a version."
      fi
    else
      say ""
      say "  WARNING: no pwsh on PATH. The guards are wired but WILL NOT FIRE."
      say "  Windows PowerShell 5.1 (powershell.exe) is a different product and"
      say "  is not enough. Install PowerShell 7 or newer, then check:"
      say "      pwsh -NoProfile -Command '\$PSVersionTable.PSVersion.ToString()'"
    fi
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
  if [ "$skipped_win" -gt 0 ]; then
    say "install: $skipped_win Windows-only file(s) skipped (not a Windows install)."
  fi
else
  say "install: $installed file(s) installed."
  if [ "$backup_made" -eq 1 ]; then
    say "install: previous versions backed up to $BACKUP"
  fi
  if [ "$skipped_settings" -eq 1 ]; then
    say "install: settings.json left alone, see the merge steps above."
  fi
  if [ "$skipped_win" -gt 0 ]; then
    say "install: $skipped_win Windows-only file(s) skipped (not a Windows install)."
  fi
  if [ "$TIER" -ge 1 ]; then
    say ""
    say "Next: the context loop is NOT in this repo. Install the public warmstart"
    say "plugin (github.com/thiagoamaro91/warmstart) if you want it."
  fi
fi
exit 0
