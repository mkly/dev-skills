#!/usr/bin/env python3
"""Guard the context loaded by the normal dev-loop path."""

from pathlib import Path
import re
import sys

try:
    import tiktoken
except ImportError:
    print("SKIP: install tiktoken to enforce skill context budgets")
    raise SystemExit(0)

root = Path(__file__).resolve().parents[2]
skills = sorted(root.glob("dev-*/SKILL.md"))
encoding = tiktoken.get_encoding("o200k_base")


def tokens(value: str) -> int:
    return len(encoding.encode(value))


def split_skill(path: Path) -> tuple[str, str]:
    parts = path.read_text().split("---\n", 2)
    if len(parts) != 3 or parts[0] != "":
        raise AssertionError(f"invalid frontmatter delimiters: {path}")
    return f"---\n{parts[1]}---\n", parts[2]


metadata_total = 0
body_counts: dict[str, int] = {}
for skill in skills:
    metadata, body = split_skill(skill)
    metadata_total += tokens(metadata)
    body_counts[str(skill.relative_to(root))] = tokens(body)

loop_body = body_counts["dev-loop/SKILL.md"]
normal_path = metadata_total + loop_body

assert metadata_total <= 350, f"metadata budget exceeded: {metadata_total} > 350"
assert normal_path <= 2500, f"normal path budget exceeded: {normal_path} > 2500"
for path, count in body_counts.items():
    assert count <= 1200, f"skill body budget exceeded: {path}: {count} > 1200"

loop_text = (root / "dev-loop/SKILL.md").read_text()
assert not re.search(r"(?is)(locate and read|read .* completely).*SKILL\.md", loop_text), \
    "dev-loop must not eagerly load component skills"

print(f"metadata={metadata_total} normal_path={normal_path}")
for path, count in body_counts.items():
    print(f"{path}={count}")
