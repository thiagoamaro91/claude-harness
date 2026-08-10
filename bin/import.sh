#!/usr/bin/env bash
# bin/import.sh - home side, reverse direction. Show what the repo has that the
# live config does not, and optionally push named changes out to the live tree.
#
#   ./bin/import.sh                       # diff every sync row, change nothing
#   ./bin/import.sh --filter hooks/       # diff only matching rows
#   ./bin/import.sh --apply hooks/guard-reread.sh
#   ./bin/import.sh --apply --all         # push every differing sync row
#
# Direction: repo -> live. Use bin/export.sh for live -> repo.
#
# What this is for: a tweak authored on the work machine, committed there,
# pulled home, and now being folded back into the live personal config. Every
# hunk gets eyeballed, because the repo copy is the scrubbed generic version
# and the live file is the personal one. Applying blindly would overwrite
# personal paths with __CLAUDE_HOME__ placeholders and break the live hook.
#
# Every applied file is backed up first, next to the original, with a
# .harness-bak-<timestamp> suffix.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO/manifest.txt"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STAMP="$(date '+%Y%m%dT%H%M%S')"

# Shared path-safety helpers (harness_relpath_ok, harness_under).
[ -r "$REPO/bin/_lib.sh" ] || { echo "import: bin/_lib.sh missing, cannot validate paths safely" >&2; exit 2; }
. "$REPO/bin/_lib.sh"

APPLY=0
ALL=0
FILTER=""
TARGETS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --all) ALL=1; shift ;;
    --filter) [ $# -ge 2 ] || { echo "import: --filter needs a value" >&2; exit 2; }
              FILTER="$2"; shift 2 ;;
    --filter=*) FILTER="${1#*=}"; shift ;;
    --config-dir) [ $# -ge 2 ] || { echo "import: --config-dir needs a value" >&2; exit 2; }
                  CONFIG_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "import: unknown flag: $1" >&2; exit 2 ;;
    *) TARGETS="$TARGETS $1"; shift ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "import: manifest not found at $MANIFEST" >&2; exit 2; }

if [ "$APPLY" -eq 1 ] && [ "$ALL" -eq 0 ] && [ -z "$TARGETS" ]; then
  echo "import: --apply needs either --all or one or more live paths." >&2
  echo "import: run without --apply first and pick from the differing rows." >&2
  exit 2
fi

wanted() { # $1 = live path
  [ "$ALL" -eq 1 ] && return 0
  [ -z "$TARGETS" ] && return 0
  # Disable globbing so the unquoted split of $TARGETS cannot expand against cwd.
  set -f
  for t in $TARGETS; do
    case "$1" in *"$t"*) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

same=0; differ=0; applied=0

echo "import: repo $REPO  ->  live $CONFIG_DIR"
echo ""

while IFS='|' read -r kind tier repo_path live_path; do
  case "$kind" in 'sync') ;; *) continue ;; esac
  [ "$live_path" != "-" ] || continue
  [ -z "$FILTER" ] || case "$live_path" in *"$FILTER"*) ;; *) continue ;; esac
  if ! harness_relpath_ok "$repo_path" || ! harness_relpath_ok "$live_path"; then
    echo "REFUSED unsafe manifest path: repo='$repo_path' live='$live_path'" >&2
    continue
  fi

  live="$CONFIG_DIR/$live_path"
  mine="$REPO/$repo_path"

  [ -f "$mine" ] || { echo "MISSING REPO  $repo_path"; continue; }

  if [ -f "$live" ] && cmp -s "$live" "$mine"; then
    same=$((same + 1))
    continue
  fi

  differ=$((differ + 1))
  if [ -f "$live" ]; then
    add=$(diff "$live" "$mine" 2>/dev/null | grep -c '^>' || true)
    del=$(diff "$live" "$mine" 2>/dev/null | grep -c '^<' || true)
    echo "DIFFERS       $live_path  (+$add / -$del if applied)"
    diff -u "$live" "$mine" 2>/dev/null | sed -n '3,$p' | sed 's/^/    /'
  else
    echo "NEW           $live_path  (no live file, would be created)"
  fi
  echo ""

  if [ "$APPLY" -eq 1 ] && wanted "$live_path"; then
    if ! harness_under "$CONFIG_DIR" "$live"; then
      echo "    REFUSED: $live_path resolves outside the config dir" >&2
      continue
    fi
    if [ -f "$live" ]; then
      cp -p "$live" "$live.harness-bak-$STAMP" || { echo "    backup failed, skipping" >&2; continue; }
      echo "    backed up to $live_path.harness-bak-$STAMP"
    fi
    mkdir -p "$(dirname "$live")"
    if cp "$mine" "$live"; then
      case "$repo_path" in *.sh) chmod +x "$live" ;; esac
      echo "    APPLIED to the live config."
      echo "    CHECK IT: any __CLAUDE_HOME__ placeholder is now literal in the"
      echo "    live file and must be replaced with $CONFIG_DIR by hand."
      applied=$((applied + 1))
    fi
    echo ""
  fi
done < "$MANIFEST"

echo "import: $same identical, $differ differing."
if [ "$APPLY" -eq 1 ]; then
  echo "import: $applied file(s) written to the live config."
  echo "import: grep the applied files for __CLAUDE_HOME__ before trusting them:"
  echo "          grep -rn __CLAUDE_HOME__ $CONFIG_DIR"
fi
exit 0
