"""Structural validation and repository conventions.

The Terraform configuration checks that every pattern parses as JSON, which is
as far as a plan-time check can reach. These tests cover the layer above:
patterns that parse, are accepted, and are still wrong.
"""

from __future__ import annotations

import pytest

from eventpattern import check_conventions, constrained_paths, validate_pattern

VALID = [
    {"source": ["com.example.orders"]},
    {"source": ["a", "b"], "detail-type": ["Order Placed"]},
    {"source": [{"prefix": "com.example."}]},
    {"source": [{"prefix": {"equals-ignore-case": "COM."}}]},
    {"source": [{"suffix": ".orders"}]},
    {"detail": {"status": [{"equals-ignore-case": "settled"}]}},
    {"detail": {"path": [{"wildcard": "orders/*/lines"}]}},
    {"detail": {"amount": [{"numeric": [">", 0]}]}},
    {"detail": {"amount": [{"numeric": [">=", 0, "<", 100]}]}},
    {"detail": {"channel": [{"anything-but": "web"}]}},
    {"detail": {"channel": [{"anything-but": ["web", "mobile"]}]}},
    {"detail": {"channel": [{"anything-but": {"prefix": "mob"}}]}},
    {"detail": {"channel": [{"anything-but": {"prefix": ["mob", "kio"]}}]}},
    {"detail": {"ip": [{"cidr": "10.0.0.0/8"}]}},
    {"detail": {"tier": [{"exists": False}]}},
    {"detail": {"amount": [{"numeric": [">", 0]}, 0]}},
    {"$or": [{"source": ["a"]}, {"source": ["b"]}]},
]


@pytest.mark.parametrize("pattern", VALID, ids=range(len(VALID)))
def test_valid_patterns_report_nothing(pattern):
    assert validate_pattern(pattern) == []


INVALID = [
    ("not an object", ["source"], "must be a JSON object"),
    ("empty object", {}, "empty object"),
    ("empty nested object", {"detail": {}}, "empty object"),
    ("empty array", {"source": []}, "empty array"),
    ("bare string value", {"source": "com.example.orders"}, "array of terms"),
    ("bare number value", {"detail": {"amount": 5}}, "array of terms"),
    ("null value", {"source": None}, "array of terms"),
    ("unknown filter", {"source": [{"starts-with": "com."}]}, "unknown content filter"),
    ("two operators", {"source": [{"prefix": "a", "suffix": "b"}]}, "exactly one operator"),
    ("prefix takes a string", {"source": [{"prefix": 5}]}, "prefix takes a string"),
    ("empty prefix", {"source": [{"prefix": ""}]}, "non-empty string"),
    ("nested filter in prefix", {"source": [{"prefix": {"suffix": "a"}}]}, "nests inside"),
    ("suffix takes a string", {"source": [{"suffix": ["a"]}]}, "suffix takes a string"),
    ("ignore-case takes a string", {"source": [{"equals-ignore-case": 1}]}, "takes a string"),
    ("wildcard takes a string", {"source": [{"wildcard": 1}]}, "wildcard takes a string"),
    ("consecutive wildcards", {"source": [{"wildcard": "a**b"}]}, "consecutive wildcards"),
    ("exists takes a boolean", {"detail": {"a": [{"exists": "true"}]}}, "true or false"),
    ("numeric arity one", {"detail": {"a": [{"numeric": [">"]}]}}, "numeric takes"),
    ("numeric arity three", {"detail": {"a": [{"numeric": [">", 1, "<"]}]}}, "numeric takes"),
    ("numeric not a list", {"detail": {"a": [{"numeric": ">1"}]}}, "numeric takes"),
    ("numeric operator", {"detail": {"a": [{"numeric": ["!=", 1]}]}}, "unknown numeric operator"),
    ("numeric operand", {"detail": {"a": [{"numeric": [">", "1"]}]}}, "compares against a number"),
    ("numeric boolean operand", {"detail": {"a": [{"numeric": [">", True]}]}}, "against a number"),
    ("cidr takes a string", {"detail": {"a": [{"cidr": 10}]}}, "cidr takes a string"),
    ("cidr is unparseable", {"detail": {"a": [{"cidr": "10.0.0.0/99"}]}}, "not a usable CIDR"),
    ("anything-but empty list", {"detail": {"a": [{"anything-but": []}]}}, "non-empty array"),
    ("anything-but mixed", {"detail": {"a": [{"anything-but": ["x", 1]}]}}, "does not mix"),
    ("anything-but bad nest", {"detail": {"a": [{"anything-but": {"cidr": "10/8"}}]}}, "not nest"),
    ("anything-but two nests",
     {"detail": {"a": [{"anything-but": {"prefix": "a", "suffix": "b"}}]}},
     "exactly one filter"),
    ("term is an array", {"source": [["a"]]}, "scalar or a content filter"),
    ("or is not a list", {"$or": {"source": ["a"]}}, "$or takes a non-empty array"),
    ("or is empty", {"$or": []}, "$or takes a non-empty array"),
    ("or branch is not an object", {"$or": ["source"]}, "branch must be an object"),
    ("or branch is invalid", {"$or": [{"source": []}]}, "empty array"),
]


@pytest.mark.parametrize("name,pattern,fragment", INVALID, ids=[case[0] for case in INVALID])
def test_invalid_patterns_are_reported(name, pattern, fragment):
    errors = validate_pattern(pattern)
    assert errors, f"{name} should have been rejected"
    assert any(fragment in error for error in errors), f"{name}: got {errors}"


def test_errors_name_the_path_that_failed():
    errors = validate_pattern({"detail": {"lines": {"sku": []}}}, label="rule")
    assert errors == ["rule.detail.lines.sku: an empty array is rejected"]


def test_every_problem_is_reported_not_just_the_first():
    errors = validate_pattern({"source": [], "detail": {"a": [{"exists": "yes"}]}})
    assert len(errors) == 2


# ---------------------------------------------------------------------------
# conventions
# ---------------------------------------------------------------------------


def test_a_pattern_keyed_on_source_is_accepted():
    assert check_conventions({"source": ["com.example.orders"]}) == []


def test_a_camel_case_envelope_field_is_reported():
    problems = check_conventions({"source": ["a"], "detailType": ["Order Placed"]})
    assert any("not an event envelope field" in problem for problem in problems)


def test_a_pattern_without_a_source_constraint_is_reported():
    problems = check_conventions({"detail-type": ["Order Placed"]})
    assert any("no constraint on source" in problem for problem in problems)


def test_or_satisfies_the_source_convention_only_when_every_branch_does():
    both = {"$or": [{"source": ["a"]}, {"source": ["b"]}]}
    assert check_conventions(both) == []
    one = {"$or": [{"source": ["a"]}, {"detail-type": ["x"]}]}
    assert any("no constraint on source" in problem for problem in check_conventions(one))


def test_replay_name_is_an_envelope_field():
    assert check_conventions({"source": ["a"], "replay-name": ["catch-up"]}) == []


# ---------------------------------------------------------------------------
# path extraction
# ---------------------------------------------------------------------------


def test_constrained_paths_walks_into_nested_objects():
    pattern = {
        "source": ["com.example.orders"],
        "detail": {"lines": {"sku": ["A"]}, "currency": ["GBP"]},
    }
    assert constrained_paths(pattern) == {
        ("source",),
        ("detail", "lines", "sku"),
        ("detail", "currency"),
    }


def test_constrained_paths_covers_every_or_branch():
    pattern = {"$or": [{"detail": {"a": ["x"]}}, {"detail": {"b": ["y"]}}]}
    assert constrained_paths(pattern) == {("detail", "a"), ("detail", "b")}
