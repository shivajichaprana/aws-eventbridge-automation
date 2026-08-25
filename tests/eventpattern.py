"""EventBridge event-pattern semantics, implemented for offline checking.

Three layers live here, kept separate on purpose:

``validate_pattern``
    Structural rules the service itself enforces. A pattern that fails these is
    rejected when the rule is created, so this layer answers "would this be
    accepted at all?".

``matches``
    Matching semantics. A pattern can be perfectly valid and still select
    nothing, which is the failure mode worth guarding against: a rule that
    matches no event looks identical to a healthy one from every angle except
    its metrics.

``check_conventions``
    Rules this repository adds on top. These are opinions, not service
    behaviour, and are reported separately so the distinction stays visible.

Nothing here calls AWS. The semantics are reimplemented from the documented
behaviour of the matching engine so that patterns can be exercised against
sample events before anything is applied.
"""

from __future__ import annotations

import ipaddress
import re
from typing import Any, Iterable, Mapping, Sequence

# Envelope fields a pattern may key on. A pattern keyed on anything else is
# almost always a camelCase slip -- "detailType" instead of "detail-type" --
# which is valid JSON, is accepted by the service, and silently matches nothing.
ENVELOPE_FIELDS = frozenset(
    {
        "account",
        "detail",
        "detail-type",
        "id",
        "region",
        "replay-name",
        "resources",
        "source",
        "time",
        "version",
    }
)

CONTENT_FILTERS = frozenset(
    {
        "anything-but",
        "cidr",
        "equals-ignore-case",
        "exists",
        "numeric",
        "prefix",
        "suffix",
        "wildcard",
    }
)

NUMERIC_OPERATORS = frozenset({"=", "<", "<=", ">", ">="})

# Filters that may be nested inside anything-but, and inside prefix/suffix as a
# case-insensitive form.
NESTABLE_IN_ANYTHING_BUT = frozenset(
    {"prefix", "suffix", "equals-ignore-case", "wildcard"}
)

_SCALAR_TYPES = (str, int, float, bool, type(None))


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _is_number(value: Any) -> bool:
    """True for JSON numbers. Booleans are not numbers, whatever Python says."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _scalar_equal(term: Any, actual: Any) -> bool:
    """Exact equality with JSON type semantics rather than Python's."""
    if isinstance(term, bool) or isinstance(actual, bool):
        return isinstance(term, bool) and isinstance(actual, bool) and term is actual
    if _is_number(term) and _is_number(actual):
        return float(term) == float(actual)
    if type(term) is not type(actual):
        return False
    return bool(term == actual)


def _wildcard_to_regex(spec: str) -> re.Pattern:
    """``*`` matches any run of characters. Nothing else is special."""
    parts = [re.escape(part) for part in spec.split("*")]
    return re.compile("^" + ".*".join(parts) + "$", re.DOTALL)


# ---------------------------------------------------------------------------
# matching
# ---------------------------------------------------------------------------


def matches(pattern: Mapping[str, Any], event: Any) -> bool:
    """Return True when ``event`` would be selected by ``pattern``.

    ``pattern`` is assumed to be structurally valid; run ``validate_pattern``
    first if that is not already established.
    """
    if not isinstance(pattern, Mapping):
        raise TypeError("an event pattern must be a JSON object")
    return _match_object(pattern, event)


def _match_object(pattern: Mapping[str, Any], value: Any) -> bool:
    # A nested pattern applied to an array matches when any element matches,
    # which is how a pattern reaches into a list of objects.
    if isinstance(value, list):
        return any(_match_object(pattern, element) for element in value)
    if not isinstance(value, Mapping):
        return False

    for key, sub in pattern.items():
        if key == "$or":
            if not isinstance(sub, Sequence) or isinstance(sub, str):
                return False
            if not any(_match_object(alt, value) for alt in sub):
                return False
            continue

        present = key in value
        actual = value.get(key)

        if isinstance(sub, Mapping):
            if not present or not _match_object(sub, actual):
                return False
        elif isinstance(sub, list):
            if not _match_terms(sub, actual, present):
                return False
        else:
            # Neither an array of terms nor a nested object: not a usable
            # pattern. validate_pattern reports this properly.
            return False
    return True


def _match_terms(terms: Iterable[Any], actual: Any, present: bool) -> bool:
    """Terms in one array are alternatives -- any match is a match."""
    return any(_match_term(term, actual, present) for term in terms)


def _match_term(term: Any, actual: Any, present: bool) -> bool:
    if isinstance(term, Mapping):
        if len(term) != 1:
            return False
        operator, argument = next(iter(term.items()))

        if operator == "exists":
            return bool(argument) is present

        if not present:
            return False

        if isinstance(actual, list):
            return any(_match_filter(operator, argument, item) for item in actual)
        return _match_filter(operator, argument, actual)

    if not present:
        return False
    if isinstance(actual, list):
        return any(_scalar_equal(term, item) for item in actual)
    return _scalar_equal(term, actual)


def _match_filter(operator: str, argument: Any, value: Any) -> bool:
    if operator == "prefix":
        return _match_affix(argument, value, prefix=True)
    if operator == "suffix":
        return _match_affix(argument, value, prefix=False)
    if operator == "equals-ignore-case":
        return isinstance(value, str) and value.lower() == str(argument).lower()
    if operator == "wildcard":
        return isinstance(value, str) and bool(_wildcard_to_regex(argument).match(value))
    if operator == "numeric":
        return _match_numeric(argument, value)
    if operator == "cidr":
        return _match_cidr(argument, value)
    if operator == "anything-but":
        return not _match_anything_but_body(argument, value)
    return False


def _match_affix(argument: Any, value: Any, *, prefix: bool) -> bool:
    if not isinstance(value, str):
        return False
    if isinstance(argument, Mapping):
        # {"prefix": {"equals-ignore-case": "..."}}
        inner = argument.get("equals-ignore-case")
        if not isinstance(inner, str):
            return False
        haystack, needle = value.lower(), inner.lower()
    else:
        haystack, needle = value, str(argument)
    return haystack.startswith(needle) if prefix else haystack.endswith(needle)


def _match_numeric(argument: Any, value: Any) -> bool:
    if not _is_number(value):
        return False
    pairs = list(zip(argument[0::2], argument[1::2]))
    for operator, operand in pairs:
        if not _is_number(operand):
            return False
        if operator == "=" and not float(value) == float(operand):
            return False
        if operator == "<" and not float(value) < float(operand):
            return False
        if operator == "<=" and not float(value) <= float(operand):
            return False
        if operator == ">" and not float(value) > float(operand):
            return False
        if operator == ">=" and not float(value) >= float(operand):
            return False
    return True


def _match_cidr(argument: Any, value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        network = ipaddress.ip_network(str(argument), strict=False)
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return address in network


def _match_anything_but_body(argument: Any, value: Any) -> bool:
    """True when ``value`` matches the body of an anything-but term."""
    if isinstance(argument, Mapping):
        if len(argument) != 1:
            return False
        operator, inner = next(iter(argument.items()))
        candidates = inner if isinstance(inner, list) else [inner]
        return any(_match_filter(operator, candidate, value) for candidate in candidates)
    if isinstance(argument, list):
        return any(_scalar_equal(candidate, value) for candidate in argument)
    return _scalar_equal(argument, value)


# ---------------------------------------------------------------------------
# structural validation
# ---------------------------------------------------------------------------


def validate_pattern(pattern: Any, *, label: str = "pattern") -> list[str]:
    """Return the structural problems in ``pattern``; empty means acceptable."""
    errors: list[str] = []
    if not isinstance(pattern, Mapping):
        return [f"{label}: an event pattern must be a JSON object"]
    _validate_object(pattern, label, errors)
    return errors


def _validate_object(node: Mapping[str, Any], path: str, errors: list[str]) -> None:
    if not node:
        errors.append(f"{path}: an empty object matches nothing and is rejected")
        return

    for key, sub in node.items():
        child = f"{path}.{key}"

        if key == "$or":
            if not isinstance(sub, list) or not sub:
                errors.append(f"{child}: $or takes a non-empty array of patterns")
                continue
            for index, alternative in enumerate(sub):
                if not isinstance(alternative, Mapping):
                    errors.append(f"{child}[{index}]: each $or branch must be an object")
                    continue
                _validate_object(alternative, f"{child}[{index}]", errors)
            continue

        if isinstance(sub, Mapping):
            _validate_object(sub, child, errors)
        elif isinstance(sub, list):
            if not sub:
                errors.append(f"{child}: an empty array is rejected")
                continue
            for index, term in enumerate(sub):
                _validate_term(term, f"{child}[{index}]", errors)
        else:
            errors.append(
                f"{child}: a value must be an array of terms or a nested object, "
                f"got {type(sub).__name__}"
            )


def _validate_term(term: Any, path: str, errors: list[str]) -> None:
    if isinstance(term, _SCALAR_TYPES):
        return
    if not isinstance(term, Mapping):
        errors.append(f"{path}: a term must be a scalar or a content filter")
        return
    if len(term) != 1:
        errors.append(
            f"{path}: a content filter holds exactly one operator, got {sorted(term)}"
        )
        return

    operator, argument = next(iter(term.items()))
    if operator not in CONTENT_FILTERS:
        errors.append(
            f"{path}: unknown content filter {operator!r}; "
            f"expected one of {sorted(CONTENT_FILTERS)}"
        )
        return

    if operator in {"prefix", "suffix"}:
        _validate_affix(operator, argument, path, errors)
    elif operator == "equals-ignore-case":
        if not isinstance(argument, str):
            errors.append(f"{path}: equals-ignore-case takes a string")
    elif operator == "wildcard":
        _validate_wildcard(argument, path, errors)
    elif operator == "exists":
        if not isinstance(argument, bool):
            errors.append(f"{path}: exists takes true or false")
    elif operator == "numeric":
        _validate_numeric(argument, path, errors)
    elif operator == "cidr":
        _validate_cidr(argument, path, errors)
    elif operator == "anything-but":
        _validate_anything_but(argument, path, errors)


def _validate_affix(operator: str, argument: Any, path: str, errors: list[str]) -> None:
    if isinstance(argument, str):
        if not argument:
            errors.append(f"{path}: {operator} takes a non-empty string")
        return
    if isinstance(argument, Mapping):
        if list(argument) != ["equals-ignore-case"] or not isinstance(
            argument.get("equals-ignore-case"), str
        ):
            errors.append(
                f"{path}: the only filter that nests inside {operator} is "
                f"equals-ignore-case with a string"
            )
        return
    errors.append(f"{path}: {operator} takes a string")


def _validate_wildcard(argument: Any, path: str, errors: list[str]) -> None:
    if not isinstance(argument, str):
        errors.append(f"{path}: wildcard takes a string")
        return
    if not argument:
        errors.append(f"{path}: wildcard takes a non-empty string")
    elif "**" in argument:
        errors.append(f"{path}: consecutive wildcards are rejected")


def _validate_numeric(argument: Any, path: str, errors: list[str]) -> None:
    if not isinstance(argument, list) or len(argument) not in (2, 4):
        errors.append(
            f"{path}: numeric takes [operator, value] or "
            f"[operator, value, operator, value]"
        )
        return
    for operator, operand in zip(argument[0::2], argument[1::2]):
        if operator not in NUMERIC_OPERATORS:
            errors.append(
                f"{path}: unknown numeric operator {operator!r}; "
                f"expected one of {sorted(NUMERIC_OPERATORS)}"
            )
        if not _is_number(operand):
            errors.append(f"{path}: numeric compares against a number, got {operand!r}")


def _validate_cidr(argument: Any, path: str, errors: list[str]) -> None:
    if not isinstance(argument, str):
        errors.append(f"{path}: cidr takes a string")
        return
    try:
        ipaddress.ip_network(argument, strict=False)
    except ValueError as exc:
        errors.append(f"{path}: {argument!r} is not a usable CIDR range ({exc})")


def _validate_anything_but(argument: Any, path: str, errors: list[str]) -> None:
    if isinstance(argument, Mapping):
        if len(argument) != 1:
            errors.append(f"{path}: anything-but nests exactly one filter")
            return
        operator, inner = next(iter(argument.items()))
        if operator not in NESTABLE_IN_ANYTHING_BUT:
            errors.append(
                f"{path}: {operator!r} does not nest inside anything-but; "
                f"expected one of {sorted(NESTABLE_IN_ANYTHING_BUT)}"
            )
            return
        values = inner if isinstance(inner, list) else [inner]
        if not values or not all(isinstance(item, str) for item in values):
            errors.append(f"{path}: anything-but/{operator} takes a string or strings")
        return

    values = argument if isinstance(argument, list) else [argument]
    if isinstance(argument, list) and not argument:
        errors.append(f"{path}: anything-but takes a value or a non-empty array")
        return
    if not all(isinstance(item, str) or _is_number(item) for item in values):
        errors.append(f"{path}: anything-but compares against strings or numbers")
    elif len({isinstance(item, str) for item in values}) > 1:
        errors.append(f"{path}: anything-but does not mix strings and numbers")


# ---------------------------------------------------------------------------
# repository conventions
# ---------------------------------------------------------------------------


def check_conventions(pattern: Mapping[str, Any], *, label: str = "pattern") -> list[str]:
    """Return convention problems: valid patterns this repository still refuses.

    Envelope-shaped only. A pipe filter is matched against the source envelope
    rather than an event envelope, so it is not put through this layer.
    """
    problems: list[str] = []
    if not isinstance(pattern, Mapping):
        return [f"{label}: an event pattern must be a JSON object"]

    for key in pattern:
        if key == "$or":
            continue
        if key not in ENVELOPE_FIELDS:
            problems.append(
                f"{label}: {key!r} is not an event envelope field. "
                f"A pattern keyed on it is accepted and then matches nothing; "
                f"expected one of {sorted(ENVELOPE_FIELDS)}"
            )

    if not _constrains_source(pattern):
        problems.append(
            f"{label}: no constraint on source. Such a pattern selects matching "
            f"events from every publisher on the bus, which is rarely intended"
        )
    return problems


def _constrains_source(pattern: Mapping[str, Any]) -> bool:
    if "source" in pattern:
        return True
    alternatives = pattern.get("$or")
    if isinstance(alternatives, list) and alternatives:
        return all(
            isinstance(alt, Mapping) and _constrains_source(alt) for alt in alternatives
        )
    return False


def constrained_paths(pattern: Mapping[str, Any], prefix: tuple[str, ...] = ()) -> set:
    """Dotted field paths a pattern constrains, e.g. ``('detail', 'status')``.

    Used to check a pattern against the contract for the events it claims to
    select: a path that no contract declares can never carry a value.
    """
    paths: set[tuple[str, ...]] = set()
    for key, sub in pattern.items():
        if key == "$or":
            if isinstance(sub, list):
                for alternative in sub:
                    if isinstance(alternative, Mapping):
                        paths |= constrained_paths(alternative, prefix)
            continue
        here = prefix + (key,)
        if isinstance(sub, Mapping):
            paths |= constrained_paths(sub, here)
        else:
            paths.add(here)
    return paths
