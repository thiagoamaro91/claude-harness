#!/usr/bin/env python3
import argparse
import datetime
import json
import os
import sys

# CONFIGURE ME: override with $AUTONOMOUS_LEDGER or --ledger.
DEFAULT_LEDGER = os.environ.get("AUTONOMOUS_LEDGER") or os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
    "autonomous",
    "runs-ledger.jsonl",
)

STR_FIELDS = ("task", "notes")
INT_FIELDS = (
    "candidates",
    "iterations",
    "stalls",
    "retries",
    "criticals_found",
    "criticals_fixed",
    "wall_min",
)
ENUM_FIELDS = {
    "head": ("code", "decision", "document", "strategy"),
    "mode": ("inline", "marathon"),
    "acceptance": ("pass", "fail", "waived"),
    "outcome": ("shipped", "draft-ready", "decided", "blocked", "vetoed"),
}
REQUIRED_FIELDS = set(STR_FIELDS) | set(INT_FIELDS) | set(ENUM_FIELDS) | {"ts"}
ALL_FIELDS = set(REQUIRED_FIELDS)


class Parser(argparse.ArgumentParser):
    # argparse's default error() exits 2, which collides with "2 = invalid
    # record"; usage problems must exit 64.
    def error(self, message):
        print("usage error: %s" % message, file=sys.stderr)
        raise SystemExit(64)


def validate(record):
    if not isinstance(record, dict):
        return "record must be a JSON object"

    unknown = set(record) - ALL_FIELDS
    if unknown:
        return "unknown field(s): %s" % ", ".join(sorted(unknown))

    missing = REQUIRED_FIELDS - {"ts"} - set(record)
    if missing:
        return "missing required field(s): %s" % ", ".join(sorted(missing))

    if "ts" in record and not isinstance(record["ts"], str):
        return "field 'ts' must be a string"

    for field in STR_FIELDS:
        if not isinstance(record[field], str):
            return "field '%s' must be a string" % field

    for field in INT_FIELDS:
        if not isinstance(record[field], int) or isinstance(record[field], bool):
            return "field '%s' must be an int" % field

    for field, allowed in ENUM_FIELDS.items():
        if record[field] not in allowed:
            return "field '%s' must be one of %s" % (field, allowed)

    return None


def main(argv):
    parser = Parser()
    parser.add_argument("--ledger", default=DEFAULT_LEDGER)
    parser.add_argument("json_arg", nargs="?", default=None)
    args = parser.parse_args(argv)

    if args.json_arg is None or args.json_arg == "-":
        raw = sys.stdin.read()
    else:
        raw = args.json_arg

    try:
        record = json.loads(raw)
    except json.JSONDecodeError as exc:
        print("invalid JSON: %s" % exc, file=sys.stderr)
        return 64

    error = validate(record)
    if error:
        print("invalid record: %s" % error, file=sys.stderr)
        return 2

    if "ts" not in record:
        record["ts"] = datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )

    try:
        parent = os.path.dirname(args.ledger)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(args.ledger, "a") as fh:
            fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
    except OSError as exc:
        print("cannot write ledger %s: %s" % (args.ledger, exc), file=sys.stderr)
        return 64

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
