"""Every pattern in the documentation, held to the same standard as code.

A reader copies these. More usefully, they are the only patterns in the
repository concrete enough to check against the published contracts, so this is
where a pattern that could never select the events it names gets caught.
"""

from __future__ import annotations

import pytest

from eventpattern import check_conventions, constrained_paths, matches, validate_pattern


def _selected_contracts(pattern, contracts):
    """Contracts whose sample event the pattern selects."""
    return {
        source: contract
        for source, contract in contracts.items()
        if matches(pattern, contract.sample_event())
    }


def _claimed_contracts(pattern, contracts):
    """Contracts the pattern names through source and detail-type.

    Envelope terms only; a pattern using a content filter on source claims
    nothing specific and is left to the matching check.
    """
    sources = [term for term in pattern.get("source", []) if isinstance(term, str)]
    detail_types = [term for term in pattern.get("detail-type", []) if isinstance(term, str)]
    claimed = {}
    for source in sources:
        contract = contracts.get(source)
        if contract is None:
            continue
        if detail_types and contract.detail_type not in detail_types:
            continue
        claimed[source] = contract
    return claimed


def test_the_readme_documents_at_least_one_pattern(documented):
    assert len(documented) >= 4


def test_documented_pattern_is_structurally_valid(documented_pattern):
    errors = validate_pattern(documented_pattern.pattern, label=documented_pattern.label)
    assert errors == []


def test_documented_pattern_follows_repository_conventions(documented_pattern):
    if not documented_pattern.envelope_shaped:
        pytest.skip("a pipe filter is matched against the source envelope, not an event")
    assert check_conventions(documented_pattern.pattern, label=documented_pattern.label) == []


def test_documented_pattern_selects_the_events_it_names(documented_pattern, contracts):
    """A pattern naming a source must actually select that contract's events.

    This is the check that catches a rule keyed on a field the producer does
    not emit: the pattern is valid, the rule is created, and nothing arrives.
    """
    if not documented_pattern.envelope_shaped:
        pytest.skip("a pipe filter is matched against the source envelope, not an event")

    claimed = _claimed_contracts(documented_pattern.pattern, contracts)
    if not claimed:
        pytest.skip("the pattern names no published contract")

    for source, contract in claimed.items():
        assert matches(documented_pattern.pattern, contract.sample_event()), (
            f"{documented_pattern.label} names {source} but does not select an event "
            f"conforming to {contract.path.name}"
        )


def test_documented_pattern_only_keys_on_fields_the_contract_declares(
    documented_pattern, contracts
):
    """A detail path absent from the contract can never carry a value."""
    if not documented_pattern.envelope_shaped:
        pytest.skip("a pipe filter is matched against the source envelope, not an event")

    claimed = _claimed_contracts(documented_pattern.pattern, contracts)
    if not claimed:
        pytest.skip("the pattern names no published contract")

    detail_paths = {
        path for path in constrained_paths(documented_pattern.pattern) if path[0] == "detail"
    }
    for source, contract in claimed.items():
        declared = contract.detail_paths()
        for path in detail_paths:
            assert path in declared, (
                f"{documented_pattern.label} filters on {'.'.join(path)}, which "
                f"{contract.path.name} ({source}) does not declare"
            )


def test_documented_pattern_respects_an_enumerated_field(documented_pattern, contracts):
    """A term outside a declared enum matches nothing, however plausible it reads."""
    if not documented_pattern.envelope_shaped:
        pytest.skip("a pipe filter is matched against the source envelope, not an event")

    claimed = _claimed_contracts(documented_pattern.pattern, contracts)
    if not claimed:
        pytest.skip("the pattern names no published contract")

    pattern = documented_pattern.pattern
    for contract in claimed.values():
        for path in constrained_paths(pattern):
            schema = contract.schema_at(path)
            if not schema or "enum" not in schema:
                continue
            terms = _terms_at(pattern, path)
            for term in terms:
                if isinstance(term, str):
                    assert term in schema["enum"], (
                        f"{documented_pattern.label} filters {'.'.join(path)} on {term!r}, "
                        f"which is not one of {schema['enum']}"
                    )


def _terms_at(pattern, path):
    node = pattern
    for segment in path:
        if not isinstance(node, dict) or segment not in node:
            return []
        node = node[segment]
    return node if isinstance(node, list) else []


def test_a_first_party_pattern_does_not_select_another_domains_events(documented, contracts):
    """A rule naming one source must not also select a different producer."""
    for documented_pattern in documented:
        if not documented_pattern.envelope_shaped:
            continue
        claimed = _claimed_contracts(documented_pattern.pattern, contracts)
        if not claimed:
            continue
        selected = _selected_contracts(documented_pattern.pattern, contracts)
        assert set(selected) == set(claimed), (
            f"{documented_pattern.label} names {sorted(claimed)} but selects "
            f"{sorted(selected)}"
        )


def test_the_partner_archive_pattern_excludes_first_party_traffic(documented, contracts):
    """The documented archive filter is meant to retain partner events only."""
    partner_patterns = [
        entry
        for entry in documented
        if entry.pattern.get("source") == [{"prefix": "partner."}]
    ]
    assert partner_patterns, "the partner archive example is no longer in the README"

    partner_event = dict(next(iter(contracts.values())).sample_event())
    partner_event["source"] = "partner.acme"

    for entry in partner_patterns:
        assert matches(entry.pattern, partner_event)
        for contract in contracts.values():
            assert not matches(entry.pattern, contract.sample_event()), (
                f"{entry.label} also retains {contract.source}"
            )
