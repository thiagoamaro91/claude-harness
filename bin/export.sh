#!/usr/bin/env bash
# bin/export.sh - home side. Show what changed in the LIVE config versus the
# repo copy, and optionally pull named changes in.
#
#   ./bin/export.sh                       # diff every sync row, change nothing
#   ./bin/export.sh --filter skills/spec  # diff only matching rows
#   ./bin/export.sh --apply skills/spec-diagram/SKILL.md
#   ./bin/export.sh --apply --all         # pull every differing sync row
#
# Direction: live -> repo. Use bin/import.sh for repo -> live.
#
# This never blind-copies the tree. The repo copies are scrubbed and
# parameterized, so they are SUPPOSED to differ from the live files: personal
# paths become __CLAUDE_HOME__, personal names become generic ones, MCP
# dependencies gain fallback lines. A diff here is information, not a defect.
# Read every hunk before applying, and re-scrub whatever you pull in.
#
# After any --apply, guard/scan.sh runs. A finding makes this script exit
# nonzero and say so, because the point of applying is to then commit.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO/manifest.txt"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STAMP="$(date '+%Y%m%dT%H%M%S')"

# Shared path-safety helpers (harness_relpath_ok, harness_under).
[ -r "$REPO/bin/_lib.sh" ] || { echo "export: bin/_lib.sh missing, cannot validate paths safely" >&2; exit 2; }
. "$REPO/bin/_lib.sh"

APPLY=0
ALL=0
FILTER=""
TARGETS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --all) ALL=1; shift ;;
    --filter) [ $# -ge 2 ] || { echo "export: --filter needs a value" >&2; exit 2; }
              FILTER="$2"; shift 2 ;;
    --filter=*) FILTER="${1#*=}"; shift ;;
    --config-dir) [ $# -ge 2 ] || { echo "export: --config-dir needs a value" >&2; exit 2; }
                  CONFIG_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "export: unknown flag: $1" >&2; exit 2 ;;
    *) TARGETS="$TARGETS $1"; shift ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "export: manifest not found at $MANIFEST" >&2; exit 2; }

if [ "$APPLY" -eq 1 ] && [ "$ALL" -eq 0 ] && [ -z "$TARGETS" ]; then
  echo "export: --apply needs either --all or one or more live paths." >&2
  echo "export: run without --apply first and pick from the differing rows." >&2
  exit 2
fi

wanted() { # $1 = live path
  [ -z "$FILTER" ] || case "$1" in *"$FILTER"*) ;; *) return 1 ;; esac
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

same=0; differ=0; missing_live=0; applied=0

echo "export: live $CONFIG_DIR  ->  repo $REPO"
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

  if [ ! -f "$live" ]; then
    echo "MISSING LIVE  $live_path"
    missing_live=$((missing_live + 1))
    continue
  fi
  if [ ! -f "$mine" ]; then
    echo "MISSING REPO  $repo_path"
    differ=$((differ + 1))
    continue
  fi
  if cmp -s "$live" "$mine"; then
    same=$((same + 1))
    continue
  fi

  differ=$((differ + 1))
  add=$(diff "$mine" "$live" 2>/dev/null | grep -c '^>' || true)
  del=$(diff "$mine" "$live" 2>/dev/null | grep -c '^<' || true)
  echo "DIFFERS       $live_path  (+$add / -$del versus the repo copy)"
  diff -u "$mine" "$live" 2>/dev/null | sed -n '3,$p' | sed 's/^/    /'
  echo ""

  if [ "$APPLY" -eq 1 ] && wanted "$live_path"; then
    if ! harness_under "$REPO" "$mine"; then
      echo "    REFUSED: $repo_path resolves outside the repo" >&2
      continue
    fi
    mkdir -p "$(dirname "$mine")"
    if [ -f "$mine" ]; then
      cp -p "$mine" "$mine.harness-bak-$STAMP" || { echo "    backup failed, skipping" >&2; continue; }
      echo "    backed up repo copy to $repo_path.harness-bak-$STAMP"
    fi
    cp "$live" "$mine" && {
      echo "    APPLIED: repo copy replaced by the live file."
      echo "    RE-SCRUB IT: personal paths, names, and MCP assumptions came"
      echo "    across with the content."
      applied=$((applied + 1))
    }
    echo ""
  fi
done < "$MANIFEST"

echo "export: $same identical, $differ differing, $missing_live missing on the live side."

if [ "$APPLY" -eq 1 ]; then
  echo "export: $applied file(s) pulled into the repo."
  echo ""
  if [ -x "$REPO/guard/scan.sh" ]; then
    if "$REPO/guard/scan.sh" "$REPO"; then
      echo "export: scan clean, safe to review and commit."
    else
      echo ""
      echo "export: SCAN FAILED. The applied content carries personal data." >&2
      echo "export: scrub the findings above before committing." >&2
      exit 1
    fi
  else
    echo "export: guard/scan.sh not executable, cannot verify. Refusing to call this done." >&2
    exit 1
  fi
fi
exit 0
