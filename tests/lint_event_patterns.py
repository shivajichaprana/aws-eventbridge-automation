#!/usr/bin/env python3
"""Lint every event pattern in the repository.

Terraform checks that a pattern parses as JSON, which is as far as a plan-time
check can reach. This walks every pattern literal in the tree and applies the
two layers above that: whether the service would accept it, and whether this
repository's conventions allow it.

Run it directly, or through ``make lint``:

    python3 tests/lint_event_patterns.py [--quiet]

Exits 1 when any pattern is rejected.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from eventpattern import check_conventions, validate_pattern  # noqa: E402
from repofiles import REPO_ROOT, documented_patterns, load_contracts  # noqa: E402

# Markdown is read strictly: every documented example should stand on its own.
# Terraform is read leniently, because most of its assignments are references
# to caller input by design and there is nothing to lint in those.
STRICT_SUFFIXES = {".md"}


def _sources() -> list[Path]:
    paths = sorted(REPO_ROOT.glob("*.md")) + sorted(REPO_ROOT.glob("*.tf"))
    paths += sorted((REPO_ROOT / "docs").glob("*.md"))
    paths += sorted((REPO_ROOT / "schemas").glob("*.md"))
    return [path for path in paths if path.is_file()]


def _lint_patterns(quiet: bool) -> tuple[int, int]:
    checked = 0
    failed = 0

    for path in _sources():
        relative = path.relative_to(REPO_ROOT)
        strict = path.suffix in STRICT_SUFFIXES
        text = path.read_text(encoding="utf-8")
        entries = documented_patterns(text, origin=str(relative), strict=strict)

        for entry in entries:
            checked += 1
            problems = validate_pattern(entry.pattern, label=entry.label)
            if entry.envelope_shaped:
                problems += check_conventions(entry.pattern, label=entry.label)

            if problems:
                failed += 1
                for problem in problems:
                    print(f"error: {problem}", file=sys.stderr)
            elif not quiet:
                print(f"  ok  {entry.label}  {json.dumps(entry.pattern)}")

    return checked, failed


def _lint_contracts(quiet: bool) -> tuple[int, int]:
    checked = 0
    failed = 0
    seen: dict[str, str] = {}

    for contract in load_contracts():
        checked += 1
        problems: list[str] = []
        if not contract.source:
            problems.append(f"{contract.path.name}: no x-amazon-events-source marker")
        if not contract.detail_type:
            problems.append(f"{contract.path.name}: no x-amazon-events-detail-type marker")
        if not contract.detail_schema.get("properties"):
            problems.append(f"{contract.path.name}: the detail schema declares no properties")

        name = contract.schema_name
        if name in seen:
            problems.append(
                f"{contract.path.name}: registers as {name}, already claimed by {seen[name]}"
            )
        seen[name] = contract.path.name

        if problems:
            failed += 1
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
        elif not quiet:
            print(f"  ok  {contract.path.name}  registers as {name}")

    return checked, failed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--quiet", action="store_true", help="only report problems")
    arguments = parser.parse_args(argv)

    if not arguments.quiet:
        print("event patterns")
    patterns_checked, patterns_failed = _lint_patterns(arguments.quiet)

    if not arguments.quiet:
        print("event contracts")
    contracts_checked, contracts_failed = _lint_contracts(arguments.quiet)

    total_failed = patterns_failed + contracts_failed
    summary = (
        f"{patterns_checked} pattern(s) and {contracts_checked} contract(s) checked, "
        f"{total_failed} rejected"
    )
    if total_failed:
        print(f"FAIL: {summary}", file=sys.stderr)
        return 1
    print(f"OK: {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
