#!/usr/bin/env python3
"""Guard the context loaded by the normal dev-loop path."""

from pathlib import Path
import re

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

# Every budget is checked before anything is reported. A bare assert per budget
# stops at the first breach and hides the rest, which is how body overruns went
# unnoticed while the metadata budget was red.
METADATA_BUDGET = 400
NORMAL_PATH_BUDGET = 2500
BODY_BUDGET = 1500

failures: list[str] = []

if metadata_total > METADATA_BUDGET:
    failures.append(f"metadata budget exceeded: {metadata_total} > {METADATA_BUDGET}")
if normal_path > NORMAL_PATH_BUDGET:
    failures.append(f"normal path budget exceeded: {normal_path} > {NORMAL_PATH_BUDGET}")
for path, count in body_counts.items():
    if count > BODY_BUDGET:
        failures.append(f"skill body budget exceeded: {path}: {count} > {BODY_BUDGET}")

loop_text = (root / "dev-loop/SKILL.md").read_text()
if re.search(r"(?is)(locate and read|read .* completely).*SKILL\.md", loop_text):
    failures.append("dev-loop must not eagerly load component skills")

print(f"metadata={metadata_total} normal_path={normal_path}")
for path, count in body_counts.items():
    print(f"{path}={count}")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    raise SystemExit(1)
