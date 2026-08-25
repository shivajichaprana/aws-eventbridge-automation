"""The published contracts, and the name each one registers under.

The registered schema name is derived from markers inside the document rather
than from the filename, so a contract that omits or misspells a marker fails at
apply. These checks bring that forward, and confirm the derivation the suite
uses is still the derivation the configuration performs.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from repofiles import DETAIL_TYPE_MARKER, REPO_ROOT, SOURCE_MARKER, load_contracts

# The nine fields EventBridge puts on every event.
ENVELOPE_REQUIRED = {
    "account",
    "detail",
    "detail-type",
    "id",
    "region",
    "resources",
    "source",
    "time",
    "version",
}

SCHEMA_NAME = re.compile(r"^[A-Za-z0-9_.@-]+$")
SOURCE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def test_contracts_are_published():
    assert load_contracts(), "no contracts found under schemas/"


def test_contract_is_an_openapi_document(contract):
    assert contract.document.get("openapi", "").startswith("3.")
    assert contract.document.get("info", {}).get("version")
    assert contract.document.get("info", {}).get("title")


def test_contract_declares_both_event_markers(contract):
    envelope = contract.document["components"]["schemas"]["AWSEvent"]
    assert envelope.get(SOURCE_MARKER), f"{contract.path.name} omits {SOURCE_MARKER}"
    assert envelope.get(DETAIL_TYPE_MARKER), f"{contract.path.name} omits {DETAIL_TYPE_MARKER}"
    assert SOURCE_NAME.match(contract.source), contract.source
    assert contract.detail_type.strip() == contract.detail_type


def test_contract_declares_the_full_envelope(contract):
    envelope = contract.document["components"]["schemas"]["AWSEvent"]
    assert set(envelope.get("required", [])) == ENVELOPE_REQUIRED
    assert set(envelope.get("properties", {})) == ENVELOPE_REQUIRED


def test_every_local_reference_resolves(contract):
    text = contract.path.read_text(encoding="utf-8")
    declared = set(contract.document["components"]["schemas"])
    for ref in re.findall(r'"\$ref"\s*:\s*"([^"]+)"', text):
        assert ref.startswith("#/components/schemas/"), f"{contract.path.name}: {ref}"
        assert ref.rsplit("/", 1)[-1] in declared, f"{contract.path.name}: {ref} is dangling"


def test_every_required_property_is_declared(contract):
    for name, schema in contract.document["components"]["schemas"].items():
        properties = set(schema.get("properties", {}))
        missing = set(schema.get("required", [])) - properties
        assert not missing, f"{contract.path.name}: {name} requires undeclared {sorted(missing)}"


def test_the_detail_schema_carries_properties(contract):
    assert contract.detail_schema.get("properties"), (
        f"{contract.path.name}: detail resolves to a schema with no properties, so no "
        f"pattern could ever key on it"
    )


def test_no_schema_component_is_left_unused(contract):
    text = contract.path.read_text(encoding="utf-8")
    for name in contract.document["components"]["schemas"]:
        if name == "AWSEvent":
            continue
        assert f"#/components/schemas/{name}" in text, (
            f"{contract.path.name}: {name} is declared but nothing references it"
        )


def test_the_derived_schema_name_is_usable(contract):
    assert SCHEMA_NAME.match(contract.schema_name), contract.schema_name
    assert " " not in contract.schema_name


def test_derived_schema_names_are_unique():
    names = [contract.schema_name for contract in load_contracts()]
    assert len(names) == len(set(names)), f"two contracts would register as one: {names}"


def test_the_derivation_matches_the_configuration():
    """Guard against the suite and the configuration drifting apart.

    If the name expression in the configuration changes, every contract check
    above keeps passing against a name that is no longer the one registered --
    unless the expression itself is asserted.
    """
    configuration = (REPO_ROOT / "event-bus.tf").read_text(encoding="utf-8")
    expected = (
        'format("%s@%s", '
        'each.value.parsed.components.schemas.AWSEvent["x-amazon-events-source"], '
        'replace(each.value.parsed.components.schemas.AWSEvent'
        '["x-amazon-events-detail-type"], " ", ""))'
    )
    assert expected in configuration, (
        "the schema name derivation in event-bus.tf no longer matches the one this "
        "suite reproduces; update Contract.schema_name alongside it"
    )


def test_a_sample_event_satisfies_its_own_contract(contract):
    """The generator is only useful if what it produces is a conforming event."""
    event = contract.sample_event()
    assert set(event) == ENVELOPE_REQUIRED
    assert event["source"] == contract.source
    assert event["detail-type"] == contract.detail_type
    for required in contract.detail_schema.get("required", []):
        assert required in event["detail"], f"{contract.path.name}: sample omits {required}"


def test_a_sample_event_respects_declared_enums(contract):
    event = contract.sample_event()
    for name, schema in (contract.detail_schema.get("properties") or {}).items():
        resolved = contract.resolve(schema)
        if "enum" in resolved:
            assert event["detail"][name] in resolved["enum"]


@pytest.mark.parametrize("path", sorted((REPO_ROOT / "schemas").glob("*.json")))
def test_contract_files_are_formatted_json(path: Path):
    """Reparsing catches a truncated or duplicated document before apply."""
    text = path.read_text(encoding="utf-8")
    assert text.endswith("\n"), f"{path.name} does not end with a newline"
    assert json.loads(text), f"{path.name} is empty"
