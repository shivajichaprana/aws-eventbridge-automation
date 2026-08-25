# Pattern checks

An event pattern is the one part of this configuration that fails silently. A
rule with a wrong pattern is created successfully, reports healthy, keeps its
targets, and never delivers anything -- because "matched nothing" and "working
normally" look identical from outside. Terraform can confirm a pattern parses as
JSON and nothing further, so these checks cover what happens after that.

Everything here runs offline against the files in this repository. No
credentials are read and no AWS API is called.

```bash
pip install -r tests/requirements.txt
pytest tests -q                     # the full suite
python3 tests/lint_event_patterns.py  # the gate CI runs on its own
```

## What is checked

| Area | File | What it establishes |
|---|---|---|
| Matching semantics | `test_pattern_matching.py` | How the engine decides a match: keys combined with and, terms with or, arrays reached into, content filters, `$or`, JSON type rules |
| Structural validation | `test_pattern_validation.py` | Patterns the service rejects -- empty arrays, unknown filters, malformed `numeric`, bad `anything-but` -- each with a negative probe |
| Conventions | `test_pattern_validation.py` | Rules this repository adds: only real envelope fields, and every rule constrains `source` |
| Documented examples | `test_documented_patterns.py` | Every pattern in the README is valid, selects the contract events it names, keys only on declared fields, and respects declared enums |
| Contracts | `test_contracts.py` | Envelope completeness, resolvable references, required properties, and the schema name each contract registers under |
| The reader | `test_hcl_reader.py` | The literal reader that lifts examples out of the documentation reads them exactly or refuses |
| The gate itself | `test_lint_cli.py` | The lint entry point passes on this tree, and fails on a polluted one |

## Conventions the checks enforce

- **A pattern keys only on real envelope fields.** `detailType` is valid JSON,
  is accepted by the service, and matches nothing. `detail-type` is the field.
- **Every rule pattern constrains `source`.** Without it a pattern selects
  matching events from every publisher on the bus, including one added later.
- **A pattern may only key on `detail` fields its contract declares.** A path
  the producer never emits cannot carry a value, so the rule matches nothing.
- **A term on an enumerated field must be one of its values.**
- **A pipe filter is exempt from the envelope conventions.** It is matched
  against the source envelope -- an SQS message, whose payload sits under
  `body` -- rather than against an event, so it has no `source` field to
  constrain.

## Adding a contract or an example

Both are discovered from disk. A new document under `schemas/` and a new
`event_pattern` in the README are picked up with no registration step, which is
deliberate: a check nobody has to remember to enable is the only kind that stays
true.

## Limitations, stated plainly

- **The matching engine is a reimplementation.** It follows the documented
  behaviour of the service and is not verified against a live bus. Where the
  documentation is ambiguous the stricter reading is taken, so a pattern these
  checks accept may still behave differently in a corner the documentation does
  not describe.
- **Size and depth limits are not encoded.** Encoding a limit incorrectly would
  reject valid patterns, which is worse than not checking, so pattern size,
  nesting depth and term counts are left to the service.
- **Only literal patterns are read.** In Markdown a value that is not a literal
  is an error, because a documented example should stand on its own. In
  Terraform it is skipped, because most assignments there are references to
  caller input and there is nothing to check.
- **Sample events are generated from the contract.** A passing check shows a
  pattern selects a conforming event, not that it selects every real one.
