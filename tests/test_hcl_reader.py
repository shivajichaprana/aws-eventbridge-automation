"""The reader that lifts pattern literals out of the documentation.

Its job is narrow: read a literal exactly, or refuse. A reader that guessed at
a value it could not parse would let a broken example through as if it had been
checked, which is worse than reporting that it could not be read.
"""

from __future__ import annotations

import pytest

from repofiles import NotLiteral, documented_patterns, read_hcl_literal


def test_reads_an_object_with_bare_and_quoted_keys():
    assert read_hcl_literal('{ source = ["a"] "detail-type" = ["B"] }') == {
        "source": ["a"],
        "detail-type": ["B"],
    }


def test_reads_a_jsonencode_call():
    assert read_hcl_literal('jsonencode({ source = ["a"] })') == {"source": ["a"]}


def test_reads_nested_structures():
    text = 'jsonencode({ detail = { lines = { sku = ["A", "B"] } } })'
    assert read_hcl_literal(text) == {"detail": {"lines": {"sku": ["A", "B"]}}}


def test_reads_scalars():
    assert read_hcl_literal("{ a = 1 b = -2.5 c = true d = false e = null }") == {
        "a": 1,
        "b": -2.5,
        "c": True,
        "d": False,
        "e": None,
    }


def test_reads_an_escaped_json_string():
    assert read_hcl_literal(r'"{\"source\":[{\"prefix\":\"partner.\"}]}"') == (
        '{"source":[{"prefix":"partner."}]}'
    )


def test_tolerates_a_trailing_comma_and_comments():
    text = """[
      # the first one
      jsonencode({ a = ["x"] }),   // and a trailing comma
    ]"""
    assert read_hcl_literal(text) == [{"a": ["x"]}]


@pytest.mark.parametrize(
    "text",
    [
        'jsonencode({ source = [var.source] })',
        '"${local.pattern}"',
        'jsonencode({ source = ["a" })',
        '"unterminated',
        "",
    ],
)
def test_refuses_anything_it_cannot_read_exactly(text):
    with pytest.raises(NotLiteral):
        read_hcl_literal(text)


def test_documented_patterns_are_discovered_from_the_readme():
    found = documented_patterns()
    assert found, "no pattern literals were found in the README"
    assert {pattern.attribute for pattern in found} <= {"event_pattern", "filter_patterns"}


def test_a_documented_pattern_carries_a_locating_label():
    text = """
```hcl
event_rules = {
  "order-placed" = {
    event_pattern = jsonencode({ source = ["com.example.orders"] })
  }
}
```
"""
    found = documented_patterns(text)
    assert len(found) == 1
    assert "order-placed.event_pattern" in found[0].label
    assert found[0].envelope_shaped is True


def test_a_pipe_filter_is_not_treated_as_envelope_shaped():
    text = 'filter_patterns = [ jsonencode({ body = { status = ["PLACED"] } }) ]'
    found = documented_patterns(text)
    assert len(found) == 1
    assert found[0].envelope_shaped is False
    assert found[0].pattern == {"body": {"status": ["PLACED"]}}
