"""Exercise revision checks, concurrent writers, and shared worktree identity."""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "scripts" / "knowledge.py"


class KnowledgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "project with spaces"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--allow-empty", "-qm", "initial")
        self.document = self.root / ".dev-knowledge.md"

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def call(self, *args, cwd=None):
        return subprocess.run([sys.executable, str(HELPER), *map(str, args)],
                              cwd=cwd or self.root, capture_output=True, text=True)

    def read(self, cwd=None):
        result = self.call("read", cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def body(self, name, text):
        path = Path(self.temp.name) / name
        path.write_text(text, encoding="utf-8")
        return path

    def create(self, text="# Knowledge\nUse the documented test setup.\n"):
        result = self.call("update", "--if-none-match", "*", "--body", self.body("initial", text))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_missing_create_update_and_stale_preconditions(self):
        initial = self.read()
        self.assertFalse(initial["exists"])
        self.assertIsNone(initial["etag"])
        self.assertFalse(self.document.exists())
        first = self.create()
        self.assertEqual(first["path"], str(self.document))
        body = self.body("replacement", "# Current\nUse pg_config.\n")
        result = self.call("update", "--if-match", first["etag"], "--body", body)
        self.assertEqual(result.returncode, 0, result.stderr)
        second = json.loads(result.stdout)
        self.assertNotEqual(first["etag"], second["etag"])
        for condition in [("--if-match", first["etag"]), ("--if-none-match", "*")]:
            rejected = self.call("update", *condition, "--body", self.body("stale", "stale text"))
            self.assertEqual(rejected.returncode, 10, rejected.stderr)
            self.assertEqual(json.loads(rejected.stderr)["status"], 412)
            self.assertEqual(self.read(), second)

    def test_one_concurrent_writer_wins(self):
        first = self.create()
        bodies = [self.body(str(i), f"# Knowledge\nUpdate {i}\n") for i in range(8)]
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda p: self.call("update", "--if-match", first["etag"], "--body", p), bodies))
        self.assertEqual(sorted(r.returncode for r in results), [0] + [10] * 7)
        winner = next(json.loads(r.stdout) for r in results if r.returncode == 0)
        self.assertEqual(self.read(), winner)

    def test_one_concurrent_creator_wins(self):
        bodies = [self.body(str(i), f"Initial {i}") for i in range(6)]
        with ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda p: self.call("update", "--if-none-match", "*", "--body", p), bodies))
        self.assertEqual(sorted(r.returncode for r in results), [0] + [10] * 5)

    def test_linked_worktree_uses_primary_document(self):
        linked = Path(self.temp.name) / "linked"
        self.git("worktree", "add", "-qb", "worker", str(linked))
        first = self.create()
        (linked / ".dev-knowledge.md").write_text("wrong local copy")
        self.assertEqual(self.read(cwd=linked), first)
        result = self.call("update", "--if-match", first["etag"], "--body",
                           self.body("replacement", "Shared update"), cwd=linked)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()["body"], "Shared update")
        self.assertEqual((linked / ".dev-knowledge.md").read_text(), "wrong local copy")

    def test_invalid_input_does_not_change_document(self):
        first = self.create()
        for text in [" ", "bad\0text", "x" * (65536 + 1)]:
            result = self.call("update", "--if-match", first["etag"], "--body", self.body("bad", text))
            self.assertEqual(result.returncode, 20, result.stderr)
            self.assertEqual(self.read(), first)
        self.assertNotEqual(self.call("update", "--body", self.body("unconditional", "oops")).returncode, 0)

    def test_symlink_is_not_read_or_overwritten(self):
        target = self.body("outside", "Do not touch")
        self.document.symlink_to(target)
        self.assertEqual(self.call("read").returncode, 20)
        self.assertEqual(self.call("update", "--if-none-match", "*", "--body", target).returncode, 20)
        self.assertEqual(target.read_text(), "Do not touch")

    def test_snapshot_etag_matches_exact_utf8_bytes_and_ignore_is_optional(self):
        text = "# Knowledge\nCafé 🐕\n"
        current = self.create(text)
        expected = '"sha256-' + hashlib.sha256(text.encode()).hexdigest() + '"'
        self.assertEqual(current["etag"], expected)
        self.assertEqual(current["body"], text)
        self.assertIn(".dev-knowledge.md", self.git("status", "--short").stdout.decode())
        (self.root / ".git" / "info" / "exclude").write_text("/.dev-knowledge.md\n")
        self.assertEqual(self.git("status", "--short").stdout, b"")
        self.assertEqual(self.read(), current)


if __name__ == "__main__":
    unittest.main()
