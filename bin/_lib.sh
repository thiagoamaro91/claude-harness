#!/usr/bin/env bash
# bin/_lib.sh - shared helpers for the sync scripts (install/export/import).
# Sourced, never executed on its own. No side effects at source time.

# harness_relpath_ok PATH
#   Succeeds (0) only for a safe manifest-supplied RELATIVE path: non-empty, not
#   absolute (no leading "/"), and with no ".." path component. Rejects (1)
#   otherwise. A ".." COMPONENT is rejected; a mere substring such as "..foo" or
#   "foo..bar" is allowed, because those are ordinary filenames.
harness_relpath_ok() {
  case "$1" in
    ""|/*) return 1 ;;
  esac
  case "/$1/" in
    */../*) return 1 ;;
  esac
  return 0
}

# harness_under BASE PATH
#   Succeeds (0) when PATH is BASE itself or lexically inside BASE. Pair it with
#   harness_relpath_ok (which forbids ".." and a leading "/") so a constructed
#   "$BASE/$relpath" provably cannot escape BASE before anything is written.
#   BASE must carry no trailing slash (the sync scripts derive it from `pwd`).
harness_under() {
  case "$2/" in
    "$1"/*) return 0 ;;
  esac
  return 1
}
