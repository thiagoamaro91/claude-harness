#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
APPEND_PY = os.path.join(HERE, "append.py")

VALID_RECORD = {
    "ts": "2026-07-28T18:00:00Z",
    "head": "code",
    "task": "smoke",
    "mode": "marathon",
    "candidates": 0,
    "iterations": 3,
    "stalls": 0,
    "retries": 0,
    "criticals_found": 0,
    "criticals_fixed": 0,
    "acceptance": "pass",
    "wall_min": 30,
    "outcome": "shipped",
    "notes": "n",
}


def run_append(record_dict, ledger_path, extra_args=None):
    args = [sys.executable, APPEND_PY, "--ledger", ledger_path]
    if extra_args:
        args.extend(extra_args)
    args.append(json.dumps(record_dict))
    return subprocess.run(args, capture_output=True, text=True)


class TestLedgerAppend(unittest.TestCase):
    def setUp(self):
        fd, path = tempfile.mkstemp(suffix=".jsonl")
        os.close(fd)
        os.remove(path)
        self.ledger = path

    def tearDown(self):
        if os.path.exists(self.ledger):
            os.remove(self.ledger)

    def test_m1_valid_record_appends(self):
        proc = run_append(VALID_RECORD, self.ledger)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(self.ledger) as fh:
            lines = fh.readlines()
        self.assertEqual(len(lines), 1)
        parsed = json.loads(lines[0])
        self.assertEqual(parsed["task"], "smoke")

    def test_m2_invalid_enum_rejected_no_file(self):
        bad = dict(VALID_RECORD)
        bad["outcome"] = "success"
        proc = run_append(bad, self.ledger)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertFalse(os.path.exists(self.ledger))

    def test_m3_missing_ts_auto_stamped(self):
        no_ts = dict(VALID_RECORD)
        del no_ts["ts"]
        proc = run_append(no_ts, self.ledger)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(self.ledger) as fh:
            line = fh.readline()
        self.assertIn('"ts":"2026-', line)
        parsed = json.loads(line)
        self.assertTrue(parsed["ts"].startswith("2026-"))

    def test_missing_required_field_rejected(self):
        missing = dict(VALID_RECORD)
        del missing["task"]
        proc = run_append(missing, self.ledger)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertFalse(os.path.exists(self.ledger))

    def test_unknown_field_rejected(self):
        extra = dict(VALID_RECORD)
        extra["bogus_field"] = "nope"
        proc = run_append(extra, self.ledger)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertFalse(os.path.exists(self.ledger))

    def test_usage_error_exits_64(self):
        proc = subprocess.run(
            [sys.executable, APPEND_PY, "--bogus-flag", "{}"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 64, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)

    def test_unwritable_ledger_exits_64(self):
        # parent path component is a plain file, so the ledger dir can't exist
        blocked = self.ledger + "-as-file"
        with open(blocked, "w") as fh:
            fh.write("x")
        try:
            proc = run_append(VALID_RECORD, os.path.join(blocked, "x.jsonl"))
            self.assertEqual(proc.returncode, 64, proc.stderr)
            self.assertIn("cannot write ledger", proc.stderr)
            self.assertNotIn("Traceback", proc.stderr)
        finally:
            os.remove(blocked)

    def test_m5_realistic_record_round_trips_14_fields(self):
        proc = run_append(VALID_RECORD, self.ledger)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(self.ledger) as fh:
            line = fh.readline()
        parsed = json.loads(line)
        self.assertEqual(set(parsed.keys()), set(VALID_RECORD.keys()))


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=2)
    if result.result.wasSuccessful():
        print("PASS: all ledger append tests green")
        sys.exit(0)
    else:
        print("FAIL: ledger append tests failed")
        sys.exit(1)
