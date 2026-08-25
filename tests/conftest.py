"""Fixtures shared by the pattern suite."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from repofiles import documented_patterns, load_contracts  # noqa: E402


@pytest.fixture(scope="session")
def contracts():
    """Every published contract, keyed by the source it describes."""
    return {contract.source: contract for contract in load_contracts()}


@pytest.fixture(scope="session")
def documented():
    """Every event pattern documented in the README."""
    return documented_patterns()


def pytest_generate_tests(metafunc):
    """Parametrise per contract and per documented pattern.

    Discovery happens from disk, so a contract or an example added later is
    covered without anyone remembering to register it here.
    """
    if "contract" in metafunc.fixturenames:
        found = load_contracts()
        metafunc.parametrize("contract", found, ids=[c.path.name for c in found])
    if "documented_pattern" in metafunc.fixturenames:
        found = documented_patterns()
        metafunc.parametrize("documented_pattern", found, ids=[p.label for p in found])
