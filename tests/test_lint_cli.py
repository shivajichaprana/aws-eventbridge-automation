"""The lint entry point CI runs.

Two things are worth proving about a gate: that it passes on the tree as it
stands, and that it would actually fail on something broken. A gate only ever
tested against a clean tree is indistinguishable from one that always passes.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import lint_event_patterns
from repofiles import REPO_ROOT

SCRIPT = Path(__file__).resolve().parent / "lint_event_patterns.py"


def test_the_repository_passes_its_own_lint():
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--quiet"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_a_clean_run_reports_what_it_checked(capsys):
    assert lint_event_patterns.main([]) == 0
    assert "pattern(s)" in capsys.readouterr().out


def _pollute(tmp_path: Path, body: str) -> Path:
    document = tmp_path / "example.md"
    document.write_text(f"```hcl\n\"broken\" = {{\n  {body}\n}}\n```\n", encoding="utf-8")
    return document


def test_a_structurally_invalid_pattern_fails_the_lint(tmp_path, monkeypatch, capsys):
    document = _pollute(tmp_path, 'event_pattern = jsonencode({ source = [] })')
    monkeypatch.setattr(lint_event_patterns, "_sources", lambda: [document])
    monkeypatch.setattr(lint_event_patterns, "REPO_ROOT", tmp_path)

    assert lint_event_patterns.main(["--quiet"]) == 1
    assert "empty array" in capsys.readouterr().err


def test_a_convention_breach_fails_the_lint(tmp_path, monkeypatch, capsys):
    document = _pollute(
        tmp_path, 'event_pattern = jsonencode({ detailType = ["Order Placed"] })'
    )
    monkeypatch.setattr(lint_event_patterns, "_sources", lambda: [document])
    monkeypatch.setattr(lint_event_patterns, "REPO_ROOT", tmp_path)

    assert lint_event_patterns.main(["--quiet"]) == 1
    assert "not an event envelope field" in capsys.readouterr().err


def test_a_pipe_filter_is_not_held_to_the_envelope_conventions(tmp_path, monkeypatch):
    """A pipe filter matches an SQS message, which has no source field."""
    document = _pollute(
        tmp_path, 'filter_patterns = [jsonencode({ body = { status = ["PLACED"] } })]'
    )
    monkeypatch.setattr(lint_event_patterns, "_sources", lambda: [document])
    monkeypatch.setattr(lint_event_patterns, "REPO_ROOT", tmp_path)

    assert lint_event_patterns.main(["--quiet"]) == 0


def test_terraform_is_read_leniently_so_a_reference_is_not_an_error():
    """Most assignments in the configuration are references, not literals."""
    configuration = (REPO_ROOT / "rules.tf").read_text(encoding="utf-8")
    assert "event_pattern  = each.value.event_pattern" in configuration
    assert lint_event_patterns.main(["--quiet"]) == 0


def test_the_linter_looks_at_every_markdown_and_terraform_file():
    covered = {path.name for path in lint_event_patterns._sources()}
    assert "README.md" in covered
    assert {"rules.tf", "event-bus.tf", "pipes.tf"} <= covered
