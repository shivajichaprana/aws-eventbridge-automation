"""Matching semantics.

A pattern that selects nothing behaves exactly like a healthy one: the rule
exists, the targets exist, no error is raised anywhere, and no event ever
arrives. These tests pin the semantics that decide the difference.
"""

from __future__ import annotations

import pytest

from eventpattern import matches

ORDER_EVENT = {
    "version": "0",
    "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "detail-type": "Order Placed",
    "source": "com.example.orders",
    "account": "123456789012",
    "time": "2026-01-01T00:00:00Z",
    "region": "us-east-1",
    "resources": ["arn:aws:s3:::example-basket"],
    "detail": {
        "orderId": "ord-1",
        "currency": "GBP",
        "totalAmount": 120.5,
        "channel": "web",
        "lines": [
            {"sku": "SKU-RED", "quantity": 1, "unitPrice": 20.5},
            {"sku": "SKU-BLUE", "quantity": 2, "unitPrice": 50.0},
        ],
    },
}


# ---------------------------------------------------------------------------
# the shape of a pattern
# ---------------------------------------------------------------------------


def test_every_declared_key_must_match():
    """Keys at one level are combined with and, not or."""
    assert matches({"source": ["com.example.orders"]}, ORDER_EVENT)
    assert not matches(
        {"source": ["com.example.orders"], "detail-type": ["Order Cancelled"]},
        ORDER_EVENT,
    )


def test_terms_in_one_array_are_alternatives():
    """Values inside a single array are combined with or."""
    assert matches({"source": ["com.example.payments", "com.example.orders"]}, ORDER_EVENT)
    assert not matches({"source": ["com.example.payments", "com.example.stock"]}, ORDER_EVENT)


def test_unmentioned_fields_are_ignored():
    """A pattern constrains what it names and nothing else."""
    assert matches({"detail-type": ["Order Placed"]}, ORDER_EVENT)


def test_a_missing_field_never_matches():
    """The commonest silent failure: keying on a field the event does not carry."""
    assert not matches({"detail": {"status": ["SETTLED"]}}, ORDER_EVENT)
    assert not matches({"detailType": ["Order Placed"]}, ORDER_EVENT)


def test_nested_objects_recurse():
    assert matches({"detail": {"currency": ["GBP"]}}, ORDER_EVENT)
    assert not matches({"detail": {"currency": ["USD"]}}, ORDER_EVENT)


def test_a_pattern_reaches_into_an_array_of_objects():
    """One matching element is enough."""
    assert matches({"detail": {"lines": {"sku": ["SKU-BLUE"]}}}, ORDER_EVENT)
    assert not matches({"detail": {"lines": {"sku": ["SKU-GREEN"]}}}, ORDER_EVENT)


def test_a_scalar_term_matches_any_element_of_an_array_field():
    assert matches({"resources": ["arn:aws:s3:::example-basket"]}, ORDER_EVENT)
    assert not matches({"resources": ["arn:aws:s3:::other"]}, ORDER_EVENT)


def test_a_pattern_value_that_is_not_an_array_or_object_matches_nothing():
    assert not matches({"source": "com.example.orders"}, ORDER_EVENT)


# ---------------------------------------------------------------------------
# content filters
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "pattern,expected",
    [
        ({"source": [{"prefix": "com.example."}]}, True),
        ({"source": [{"prefix": "partner."}]}, False),
        ({"source": [{"prefix": {"equals-ignore-case": "COM.EXAMPLE."}}]}, True),
        ({"source": [{"suffix": ".orders"}]}, True),
        ({"source": [{"suffix": ".payments"}]}, False),
        ({"detail-type": [{"equals-ignore-case": "order placed"}]}, True),
        ({"detail-type": [{"equals-ignore-case": "order cancelled"}]}, False),
        ({"source": [{"wildcard": "com.*.orders"}]}, True),
        ({"source": [{"wildcard": "com.*.payments"}]}, False),
        ({"detail": {"channel": [{"anything-but": "mobile"}]}}, True),
        ({"detail": {"channel": [{"anything-but": "web"}]}}, False),
        ({"detail": {"channel": [{"anything-but": ["web", "mobile"]}]}}, False),
        ({"detail": {"channel": [{"anything-but": {"prefix": "mob"}}]}}, True),
        ({"detail": {"totalAmount": [{"numeric": [">", 100]}]}}, True),
        ({"detail": {"totalAmount": [{"numeric": [">", 200]}]}}, False),
        ({"detail": {"totalAmount": [{"numeric": [">=", 100, "<", 200]}]}}, True),
        ({"detail": {"totalAmount": [{"numeric": ["=", 120.5]}]}}, True),
        ({"detail": {"channel": [{"exists": True}]}}, True),
        ({"detail": {"channel": [{"exists": False}]}}, False),
        ({"detail": {"discount": [{"exists": False}]}}, True),
        ({"detail": {"discount": [{"exists": True}]}}, False),
    ],
)
def test_content_filters(pattern, expected):
    assert matches(pattern, ORDER_EVENT) is expected


def test_numeric_ignores_a_value_that_is_not_a_number():
    assert not matches({"detail": {"currency": [{"numeric": [">", 0]}]}}, ORDER_EVENT)


def test_cidr_matches_an_address_inside_the_range():
    event = {"source": ["x"], "detail": {"sourceIp": "10.1.2.3"}}
    assert matches({"detail": {"sourceIp": [{"cidr": "10.1.0.0/16"}]}}, event)
    assert not matches({"detail": {"sourceIp": [{"cidr": "10.2.0.0/16"}]}}, event)


def test_a_content_filter_reaches_elements_of_an_array_field():
    assert matches({"detail": {"lines": {"sku": [{"prefix": "SKU-B"}]}}}, ORDER_EVENT)
    assert matches({"detail": {"lines": {"quantity": [{"numeric": [">", 1]}]}}}, ORDER_EVENT)
    assert not matches({"detail": {"lines": {"quantity": [{"numeric": [">", 5]}]}}}, ORDER_EVENT)


def test_wildcard_does_not_treat_a_question_mark_as_special():
    event = {"source": "com.example.orders", "detail": {"path": "/a/b"}}
    assert not matches({"detail": {"path": [{"wildcard": "/?/b"}]}}, event)
    assert matches({"detail": {"path": [{"wildcard": "/*/b"}]}}, event)


# ---------------------------------------------------------------------------
# $or
# ---------------------------------------------------------------------------


def test_or_matches_when_any_branch_matches():
    pattern = {
        "source": ["com.example.orders"],
        "$or": [
            {"detail": {"channel": ["store"]}},
            {"detail": {"totalAmount": [{"numeric": [">", 100]}]}},
        ],
    }
    assert matches(pattern, ORDER_EVENT)


def test_or_fails_when_no_branch_matches():
    pattern = {
        "$or": [
            {"detail": {"channel": ["store"]}},
            {"detail": {"totalAmount": [{"numeric": [">", 500]}]}},
        ]
    }
    assert not matches(pattern, ORDER_EVENT)


def test_or_is_combined_with_its_siblings_by_and():
    pattern = {
        "source": ["com.example.payments"],
        "$or": [{"detail": {"channel": ["web"]}}],
    }
    assert not matches(pattern, ORDER_EVENT)


# ---------------------------------------------------------------------------
# json types
# ---------------------------------------------------------------------------


def test_a_boolean_does_not_match_a_number():
    event = {"detail": {"flagged": True, "count": 1}}
    assert matches({"detail": {"flagged": [True]}}, event)
    assert not matches({"detail": {"count": [True]}}, event)
    assert not matches({"detail": {"flagged": [1]}}, event)


def test_an_integer_and_a_float_of_equal_value_match():
    event = {"detail": {"quantity": 2}}
    assert matches({"detail": {"quantity": [2.0]}}, event)


def test_a_string_does_not_match_a_number_of_the_same_text():
    event = {"detail": {"code": "200"}}
    assert not matches({"detail": {"code": [200]}}, event)


def test_matches_rejects_a_pattern_that_is_not_an_object():
    with pytest.raises(TypeError):
        matches(["source"], ORDER_EVENT)
