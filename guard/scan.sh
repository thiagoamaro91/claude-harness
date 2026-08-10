#!/usr/bin/env bash
# guard/scan.sh - refuse to let personal or client data into this repo.
#
# Scans TRACKED files only (git ls-files, so staged-but-uncommitted files are
# covered too) for two pattern sets:
#
#   PASS A  structural markers that are generic and safe to state in the open,
#           so they live in this file: absolute home paths (any user), personal
#           note-vault paths and URL schemes, note-store tool names, known
#           personal hostnames, private-range and tailnet hosts, chat ids,
#           IBAN-shaped strings, note-store and context filenames, the U+2014
#           em-dash (matched by its byte sequence), and any email address.
#   PASS B  the private denylist at guard/denylist.local (gitignored, one
#           extended regex per line, "#" comments allowed). Real names,
#           employer and client names, internal hostnames, phone numbers. Those
#           strings must never be written into a committed file, this one
#           included, which is why the list lives outside the repo.
#
# PASS A skips this file and guard/denylist.example, which necessarily contain
# their own patterns. PASS B does NOT skip them: the private words must not
# appear anywhere, and that is exactly the blind spot a self-exclusion would
# open.
#
# The committer's own email address is fine in git metadata (author/committer),
# but it must NOT appear inside a tracked file, so it is deliberately not
# exempted from the content scan. Only the SSH-remote form git@<host> (a URL,
# not a mailbox) and the reserved example.com / example.org domains are allowed.
#
# Fail-closed: if guard/denylist.local exists but is inert (zero active
# patterns) or still carries an ACTIVE PLACEHOLDER line from the template, the
# scan FAILS. A verbatim copy of guard/denylist.example fails here until its
# fill-in sections are replaced: an inert denylist reads as "configured" while
# catching nothing, which is worse than none at all.
#
# Exit 0 clean, exit 1 with file:line findings (or a disarmed denylist), exit 2
# on a usage/environment error. POSIX-portable: no GNU-only grep flags, no \b
# (BSD grep does not honor it in ERE).
#
# Usage: guard/scan.sh [repo-root]

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "scan: cannot cd to $ROOT" >&2; exit 2; }

command -v git >/dev/null 2>&1 || { echo "scan: git not found" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "scan: $ROOT is not a git repo" >&2; exit 2; }

SELF="guard/scan.sh"
EXAMPLE="guard/denylist.example"
DENYLIST="guard/denylist.local"

# Per-run scratch dir, honoring $TMPDIR, unpredictable name, auto-cleaned. No
# predictable PID-named temp file that another user on a shared box could
# pre-create or race.
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/harness-scan.XXXXXX") || { echo "scan: cannot create temp dir" >&2; exit 2; }
trap 'rm -rf "$TMPD"' EXIT INT TERM

findings=0

# Tracked files, NUL-safe, text only. Anything git considers binary is skipped:
# grep would spew, and a binary blob has no business here in the first place.
tracked_text() {
  git ls-files -z | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    if git check-attr binary -- "$f" 2>/dev/null | grep -q ': binary: set$'; then continue; fi
    case "$(file -b --mime-encoding "$f" 2>/dev/null)" in
      binary) continue ;;
    esac
    printf '%s\n' "$f"
  done
}

report() { # $1 label, $2 file:line:text
  printf '  [%s] %s\n' "$1" "$2"
  findings=$((findings + 1))
}

# --- PASS A patterns ---------------------------------------------------------
# Written as "label<TAB>ERE". Each pattern brackets its first (or a dot)
# character so this file does not itself contain the literal string it hunts
# for, and neither does the private denylist a user copies from the example.
pass_a() {
  cat <<'PATTERNS'
abs-home-path	/[U]sers/[A-Za-z0-9._-]+
abs-home-path	/[h]ome/[A-Za-z0-9._-]+/\.claude
personal-vault	[i]Cloud~[a-z]+~obsidian
vault-url	[o]bsidian://
note-tool	[o]bsidian_[a-z]
personal-host	[m]ini\.local
tailnet-host	[a-z0-9-]+\.ts\.net
private-ip	192[.]168[.]
mobile-docs	[M]obile Documents
git-store	[.]git-stores
launch-agents	[L]aunchAgents
note-store	[M]EMORY\.md
context-index	[c]ontext_index\.md
iban-shaped	[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}
PATTERNS
}

echo "scan: PASS A (structural markers)"
tracked_text | while IFS= read -r f; do
  case "$f" in
    "$SELF"|"$EXAMPLE") continue ;;
  esac
  pass_a | while IFS="$(printf '\t')" read -r label pat; do
    [ -n "$pat" ] || continue
    grep -nE "$pat" "$f" 2>/dev/null | while IFS= read -r hit; do
      printf 'FINDING\t%s\t%s:%s\n' "$label" "$f" "$hit"
    done
  done
done > "$TMPD/a"

# em-dash (U+2014): matched by its UTF-8 byte sequence, built at runtime so this
# file never contains the character it forbids. Fixed-string match, case-moot.
EMDASH=$(printf '\342\200\224')
tracked_text | while IFS= read -r f; do
  case "$f" in
    "$SELF"|"$EXAMPLE") continue ;;
  esac
  grep -nF "$EMDASH" "$f" 2>/dev/null | while IFS= read -r hit; do
    printf 'FINDING\tem-dash\t%s:%s\n' "$f" "$hit"
  done
done >> "$TMPD/a"

# chat-id: 8 or more consecutive digits on a line that also mentions a chat
# transport. The word alone is fine; the word next to an id is not.
tracked_text | while IFS= read -r f; do
  case "$f" in
    "$SELF"|"$EXAMPLE") continue ;;
  esac
  grep -nEi 'telegram|whatsapp|signal' "$f" 2>/dev/null | grep -E '[0-9]{8,}' | while IFS= read -r hit; do
    printf 'FINDING\tchat-id\t%s:%s\n' "$f" "$hit"
  done
done >> "$TMPD/a"

# email: any address. The committer's own address is caught here on purpose (it
# belongs in git metadata, not in file content). Only the SSH-remote form
# git@<host>, which is a URL and not a mailbox, and the reserved example.com /
# example.org domains are allowed.
tracked_text | while IFS= read -r f; do
  case "$f" in
    "$SELF"|"$EXAMPLE") continue ;;
  esac
  grep -noE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f" 2>/dev/null | while IFS= read -r hit; do
    addr="${hit#*:}"
    case "$addr" in
      git@*) continue ;;
      *@example.com|*@example.org) continue ;;
    esac
    printf 'FINDING\temail\t%s:%s\n' "$f" "$hit"
  done
done >> "$TMPD/a"

while IFS="$(printf '\t')" read -r _ label loc; do
  report "$label" "$loc"
done < "$TMPD/a"

# --- PASS B: the private denylist -------------------------------------------
if [ -f "$DENYLIST" ]; then
  # Fail closed on a template or inert denylist. This is the whole point: a
  # denylist that exists but catches nothing must not pass silently. The check
  # keys on ACTIVE (non-comment, non-blank) lines only, so instruction comments
  # in a copied template may mention the token freely, while a verbatim copy of
  # guard/denylist.example (whose fill-in sections ship as active PLACEHOLDER
  # sentinels) fails here until the user replaces them with real patterns.
  if grep -vE '^[[:space:]]*(#|$)' "$DENYLIST" | grep -qF 'PLACEHOLDER'; then
    echo "scan: FAIL, $DENYLIST is not configured: replace the PLACEHOLDER lines" >&2
    echo "      with your real patterns (one regex per line) and delete each" >&2
    echo "      PLACEHOLDER sentinel before pushing." >&2
    exit 1
  fi
  active=$(grep -cvE '^[[:space:]]*(#|$)' "$DENYLIST" || true)
  if [ "${active:-0}" -eq 0 ]; then
    echo "scan: FAIL, $DENYLIST has zero active patterns; the private guard is disarmed." >&2
    echo "      Copy guard/denylist.example and replace its PLACEHOLDER sentinels with" >&2
    echo "      your own names, employer, hosts, and phone patterns before pushing." >&2
    exit 1
  fi
  echo "scan: PASS B (private denylist, $active patterns)"
  tracked_text > "$TMPD/files"
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    while IFS= read -r f; do
      grep -nEi "$pat" "$f" 2>/dev/null | while IFS= read -r hit; do
        printf 'FINDING\tdenylist\t%s:%s\n' "$f" "$hit"
      done
    done < "$TMPD/files"
  done < "$DENYLIST" > "$TMPD/b"
  while IFS="$(printf '\t')" read -r _ label loc; do
    report "$label" "$loc"
  done < "$TMPD/b"
else
  # Absent denylist.local is the fresh-clone state: the file is gitignored and
  # never travels with a clone, so a checkout on a new machine has no private
  # guard at all. Fail closed exactly like the zero-active-patterns case, rather
  # than falling through to "scan: clean" and reporting a fail-open pass.
  echo "scan: FAIL, $DENYLIST is not present; the private guard is absent." >&2
  echo "      Copy guard/denylist.example to guard/denylist.local and fill it in" >&2
  echo "      before the guard can pass." >&2
  exit 1
fi

if [ "$findings" -gt 0 ]; then
  echo "scan: FAIL, $findings finding(s)"
  exit 1
fi
echo "scan: clean"
exit 0
