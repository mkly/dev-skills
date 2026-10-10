#!/usr/bin/env python3
"""Local Markdown document with ETag/If-Match semantics for cooperating writers."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


MAX_BYTES = 64 * 1024


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, check=True)
    return result.stdout


def locations():
    common = Path(os.fsdecode(git("rev-parse", "--path-format=absolute", "--git-common-dir")).strip())
    # Git lists the main worktree first. -z preserves spaces and newlines in paths.
    fields = git("worktree", "list", "--porcelain", "-z").split(b"\0")
    if not fields or not fields[0].startswith(b"worktree ") or b"bare" in fields[:3]:
        raise ValueError("a primary non-bare checkout is required")
    root = Path(os.fsdecode(fields[0][len(b"worktree "):]))
    if not root.is_dir():
        raise ValueError("primary checkout is unavailable")
    return root / ".dev-knowledge.md", common / "dev-knowledge.lock"


def validate(data):
    if len(data) > MAX_BYTES:
        raise ValueError("working knowledge exceeds 64 KiB; shorten it before saving")
    body = data.decode("utf-8")
    if "\0" in body:
        raise ValueError("working knowledge must not contain NUL characters")
    return body


def snapshot(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None, None
    with os.fdopen(fd, "rb") as stream:
        mode = os.fstat(stream.fileno()).st_mode
        if not stat.S_ISREG(mode):
            raise ValueError("working knowledge must be a regular file, not a symlink or device")
        data = stream.read(MAX_BYTES + 1)
    validate(data)
    return data, stat.S_IMODE(mode)


def etag(data):
    return None if data is None else '"sha256-' + hashlib.sha256(data).hexdigest() + '"'


def representation(path, data):
    return {"path": str(path), "exists": data is not None,
            "etag": etag(data), "body": "" if data is None else validate(data)}


@contextlib.contextmanager
def locked(path, exclusive):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        yield
    finally:
        os.close(fd)


def replace(path, data, mode):
    fd, name = tempfile.mkstemp(prefix=".dev-knowledge-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode if mode is not None else 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    read = commands.add_parser("read", help="read a consistent body and ETag; missing is normal")
    read.add_argument("--format", choices=["json", "prompt"], default="json")
    update = commands.add_parser("update", help="conditionally replace the Markdown document")
    condition = update.add_mutually_exclusive_group(required=True)
    condition.add_argument("--if-match", help="exact quoted ETag returned by read")
    condition.add_argument("--if-none-match", choices=["*"], help="create only if absent")
    update.add_argument("--body", required=True, type=Path, help="replacement UTF-8 Markdown file")
    args = parser.parse_args()
    # Read candidate before locking: slow input never holds up other writers.
    candidate = None
    if args.command == "update":
        with args.body.open("rb") as stream:
            candidate = stream.read(MAX_BYTES + 1)
        if not validate(candidate).strip():
            raise ValueError("replacement must contain Markdown text")
    path, lock = locations()
    with locked(lock, args.command == "update"):
        current, mode = snapshot(path)
        if args.command == "update":
            matches = (current is None if args.if_none_match else
                       current is not None and args.if_match == etag(current))
            if not matches:
                print(json.dumps({"error": "precondition_failed", "status": 412,
                                  "path": str(path), "etag": etag(current),
                                  "message": "Reread and reconsider the update."}), file=sys.stderr)
                return 10
            if candidate != current:
                replace(path, candidate, mode)
            current = candidate
        result = representation(path, current)
    if args.command == "read" and args.format == "prompt":
        print("Project working knowledge (context for this run)")
        print("Path: " + result["path"])
        if result["exists"]:
            print("ETag: " + result["etag"])
            print("\n" + result["body"])
        else:
            print("No document exists yet. Create only when reusable knowledge warrants it.")
    else:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("dev-knowledge: " + str(error), file=sys.stderr)
        sys.exit(20)
