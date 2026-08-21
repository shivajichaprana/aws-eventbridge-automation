# Event contracts

Each file here is one event type's published contract: what a producer promises to emit,
in the OpenAPI 3 form that EventBridge Schemas accepts. Contracts are registered into the
curated registry, kept separate from the AWS-managed `discovered-schemas` registry that
inference writes into. Inference describes what happened; a contract is an agreement.

## Conventions

- **One file per event type**, named after the event in kebab case.
- **The `AWSEvent` component carries the routing markers.** `x-amazon-events-source` and
  `x-amazon-events-detail-type` must both be present. The registered schema name is
  derived from them as `<source>@<DetailTypeWithoutSpaces>`, which is the same convention
  discovery uses, so a contract and its discovered counterpart line up.
- **`info.version` is mandatory.** Consumers pin a generated binding to a version; an
  unversioned contract cannot be depended on.
- **The payload lives under `detail`.** Envelope fields are fixed by EventBridge; only the
  `detail` schema is yours to design.

Both rules are enforced at plan time, so a contract missing either marker or a version is
rejected before it can be published.

## Evolving a contract

Adding an optional field is backward compatible and only needs a minor version bump.
Removing a field, renaming one, or making an optional field required is a breaking change:
publish it as a new detail type rather than editing the existing contract, run both for a
deprecation window, and retire the old one once consumers have moved. The archive retains
events in their original shape, so a replay after a breaking change replays the old shape.

## Adding a contract

Drop a new `.json` file in this directory. It is discovered and published automatically —
no Terraform change is required.
