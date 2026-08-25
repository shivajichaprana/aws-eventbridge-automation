"""Reads the repository's own artefacts so patterns can be checked against them.

Two sources are pulled in.

Documented patterns
    Every ``event_pattern`` and ``filter_patterns`` value in the README. These
    are the examples a reader copies, so they are worth holding to the same
    standard as code. Only literal values are collected; anything carrying an
    interpolation or a variable reference is reported as such rather than
    guessed at.

Event contracts
    The OpenAPI documents under ``schemas/``. Each one states what a producer
    promises to emit, which is what makes it possible to ask whether a pattern
    would actually select those events.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_DIR = REPO_ROOT / "schemas"
README = REPO_ROOT / "README.md"

# The two markers that tie an OpenAPI document to the events it describes.
SOURCE_MARKER = "x-amazon-events-source"
DETAIL_TYPE_MARKER = "x-amazon-events-detail-type"


class NotLiteral(ValueError):
    """Raised when an HCL value depends on something outside the document."""


# ---------------------------------------------------------------------------
# a very small HCL literal reader
# ---------------------------------------------------------------------------


class _LiteralReader:
    """Reads one HCL literal value: object, array, string, number, or boolean.

    Deliberately narrow. Identifiers, interpolations and function calls other
    than ``jsonencode`` raise NotLiteral rather than being approximated, so a
    value is either read exactly or reported as unreadable.
    """

    def __init__(self, text: str, position: int = 0) -> None:
        self.text = text
        self.position = position

    def read_value(self) -> Any:
        self._skip_trivia()
        if self.position >= len(self.text):
            raise NotLiteral("value ended before it began")

        char = self.text[self.position]
        if char == "{":
            return self._read_object()
        if char == "[":
            return self._read_array()
        if char == '"':
            return self._read_string()
        if self.text.startswith("jsonencode(", self.position):
            self.position += len("jsonencode(")
            value = self.read_value()
            self._skip_trivia()
            self._expect(")")
            return value
        return self._read_bare()

    # -- structure ------------------------------------------------------

    def _read_object(self) -> dict:
        self._expect("{")
        result: dict[str, Any] = {}
        while True:
            self._skip_trivia()
            if self._peek() == "}":
                self.position += 1
                return result
            key = self._read_key()
            self._skip_trivia()
            self._expect("=")
            result[key] = self.read_value()
            self._skip_trivia()
            if self._peek() == ",":
                self.position += 1

    def _read_array(self) -> list:
        self._expect("[")
        result: list[Any] = []
        while True:
            self._skip_trivia()
            if self._peek() == "]":
                self.position += 1
                return result
            result.append(self.read_value())
            self._skip_trivia()
            if self._peek() == ",":
                self.position += 1

    def _read_key(self) -> str:
        if self._peek() == '"':
            return self._read_string()
        match = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*").match(self.text, self.position)
        if not match:
            raise NotLiteral(f"unreadable key at offset {self.position}")
        self.position = match.end()
        return match.group(0)

    # -- scalars --------------------------------------------------------

    def _read_string(self) -> str:
        self._expect('"')
        out: list[str] = []
        while True:
            if self.position >= len(self.text):
                raise NotLiteral("unterminated string")
            char = self.text[self.position]
            if char == "\\":
                nxt = self.text[self.position + 1]
                out.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
                self.position += 2
                continue
            if char == '"':
                self.position += 1
                return "".join(out)
            if char == "$" and self.text.startswith("${", self.position):
                raise NotLiteral("string carries an interpolation")
            out.append(char)
            self.position += 1

    def _read_bare(self) -> Any:
        match = re.compile(r"[A-Za-z0-9_.\-+]+").match(self.text, self.position)
        if not match:
            raise NotLiteral(f"unreadable value at offset {self.position}")
        token = match.group(0)
        self.position = match.end()
        if token == "true":
            return True
        if token == "false":
            return False
        if token == "null":
            return None
        try:
            return int(token) if re.fullmatch(r"-?\d+", token) else float(token)
        except ValueError as exc:
            raise NotLiteral(f"{token!r} is not a literal") from exc

    # -- plumbing -------------------------------------------------------

    def _peek(self) -> str:
        return self.text[self.position] if self.position < len(self.text) else ""

    def _expect(self, char: str) -> None:
        if self._peek() != char:
            raise NotLiteral(f"expected {char!r} at offset {self.position}")
        self.position += 1

    def _skip_trivia(self) -> None:
        while self.position < len(self.text):
            char = self.text[self.position]
            if char in " \t\r\n":
                self.position += 1
            elif char == "#" or self.text.startswith("//", self.position):
                end = self.text.find("\n", self.position)
                self.position = len(self.text) if end < 0 else end + 1
            elif self.text.startswith("/*", self.position):
                end = self.text.find("*/", self.position)
                if end < 0:
                    raise NotLiteral("unterminated block comment")
                self.position = end + 2
            else:
                return


def read_hcl_literal(text: str, position: int = 0) -> Any:
    """Read a single HCL literal value starting at ``position``."""
    return _LiteralReader(text, position).read_value()


# ---------------------------------------------------------------------------
# documented patterns
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DocumentedPattern:
    """One pattern literal found in the README, with where it came from."""

    label: str
    attribute: str
    line: int
    pattern: Any
    envelope_shaped: bool


_ASSIGNMENT = re.compile(r"^\s*(event_pattern|filter_patterns)\s*=", re.MULTILINE)
_BLOCK_KEY = re.compile(r'^\s*"([A-Za-z0-9._-]+)"\s*=\s*\{', re.MULTILINE)


def _enclosing_key(text: str, offset: int) -> str:
    """The nearest quoted block key above ``offset``, for readable labels."""
    best = ""
    for match in _BLOCK_KEY.finditer(text, 0, offset):
        best = match.group(1)
    return best or "example"


def documented_patterns(
    text: str | None = None,
    origin: str = "README",
    *,
    strict: bool = True,
) -> list[DocumentedPattern]:
    """Every literal event pattern in ``text``, defaulting to the README.

    With ``strict`` off, an assignment whose value is not a literal -- one
    referring to a variable, say -- is skipped instead of raising. The
    documentation is read strictly because every example there should be
    self-contained; the configuration is read leniently because most of its
    assignments are references by design.
    """
    if text is None:
        text = README.read_text(encoding="utf-8")
    found: list[DocumentedPattern] = []

    for match in _ASSIGNMENT.finditer(text):
        attribute = match.group(1)
        try:
            value = read_hcl_literal(text, match.end())
        except NotLiteral:
            if strict:
                raise
            continue
        line = text.count("\n", 0, match.start()) + 1
        key = _enclosing_key(text, match.start())
        # A pipe filter is matched against the source envelope -- an SQS
        # message, not an event -- so it is not envelope-shaped.
        envelope = attribute == "event_pattern"

        candidates = value if isinstance(value, list) else [value]
        for index, candidate in enumerate(candidates):
            decoded = json.loads(candidate) if isinstance(candidate, str) else candidate
            suffix = f"[{index}]" if isinstance(value, list) else ""
            found.append(
                DocumentedPattern(
                    label=f"{origin}:{line} {key}.{attribute}{suffix}",
                    attribute=attribute,
                    line=line,
                    pattern=decoded,
                    envelope_shaped=envelope,
                )
            )
    return found


# ---------------------------------------------------------------------------
# event contracts
# ---------------------------------------------------------------------------


@dataclass
class Contract:
    """One published event contract, with a sample event it describes."""

    path: Path
    document: dict
    source: str
    detail_type: str
    detail_schema: dict = field(default_factory=dict)

    @property
    def schema_name(self) -> str:
        """The name the contract registers under, derived as the module derives it."""
        return f"{self.source}@{self.detail_type.replace(' ', '')}"

    def resolve(self, node: Any) -> Any:
        """Follow a local ``$ref`` to the component it names."""
        if isinstance(node, dict) and "$ref" in node:
            ref = node["$ref"]
            if not ref.startswith("#/components/schemas/"):
                raise KeyError(f"{self.path.name}: only local refs are supported: {ref}")
            name = ref.rsplit("/", 1)[-1]
            return self.document["components"]["schemas"][name]
        return node

    def detail_paths(self, prefix: tuple[str, ...] = ("detail",)) -> set:
        """Dotted paths a pattern may legitimately key on, arrays flattened."""
        return self._paths(self.detail_schema, prefix)

    def _paths(self, schema: dict, prefix: tuple[str, ...]) -> set:
        schema = self.resolve(schema)
        paths: set[tuple[str, ...]] = set()
        if schema.get("type") == "array":
            return self._paths(schema.get("items", {}), prefix)
        for name, sub in (schema.get("properties") or {}).items():
            here = prefix + (name,)
            paths.add(here)
            paths |= self._paths(sub, here)
        return paths

    def schema_at(self, path: tuple) -> dict | None:
        """The contract node a dotted pattern path lands on, or None.

        ``path`` is rooted at the envelope, so ``("detail", "method")`` walks
        into the detail schema. Arrays are stepped through rather than into,
        matching how the engine reaches elements of a list.
        """
        if not path or path[0] != "detail":
            return None
        node: Any = self.detail_schema
        for segment in path[1:]:
            node = self.resolve(node)
            while node.get("type") == "array":
                node = self.resolve(node.get("items", {}))
            properties = node.get("properties") or {}
            if segment not in properties:
                return None
            node = properties[segment]
        return self.resolve(node)

    def sample_event(self) -> dict:
        """A representative event conforming to this contract."""
        return {
            "version": "0",
            "id": "11111111-2222-3333-4444-555555555555",
            "detail-type": self.detail_type,
            "source": self.source,
            "account": "123456789012",
            "time": "2026-01-01T00:00:00Z",
            "region": "us-east-1",
            "resources": [],
            "detail": self._sample(self.detail_schema),
        }

    def _sample(self, schema: Any, name: str = "") -> Any:
        schema = self.resolve(schema)
        if "enum" in schema:
            return schema["enum"][0]
        kind = schema.get("type", "object")
        if kind == "object":
            return {
                key: self._sample(sub, key)
                for key, sub in (schema.get("properties") or {}).items()
            }
        if kind == "array":
            return [self._sample(schema.get("items", {"type": "string"}), name)]
        if kind == "integer":
            return 2
        if kind == "number":
            return 49.95
        if kind == "boolean":
            return True
        if schema.get("format") == "date-time":
            return "2026-01-01T00:00:00Z"
        return f"sample-{name or 'value'}"


def load_contracts(directory: Path | None = None) -> list[Contract]:
    """Every contract under ``schemas/``, ordered by filename."""
    schema_dir = directory or SCHEMA_DIR
    contracts: list[Contract] = []
    for path in sorted(schema_dir.glob("*.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        envelope = document.get("components", {}).get("schemas", {}).get("AWSEvent", {})
        contract = Contract(
            path=path,
            document=document,
            source=envelope.get(SOURCE_MARKER, ""),
            detail_type=envelope.get(DETAIL_TYPE_MARKER, ""),
        )
        detail = envelope.get("properties", {}).get("detail", {})
        contract.detail_schema = contract.resolve(detail) if detail else {}
        contracts.append(contract)
    return contracts
