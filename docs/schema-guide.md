# Schema guide

A bus decouples a producer from its consumers, which means nobody is left holding the
question of what an event actually looks like. A contract is the answer: a published,
versioned document stating what a producer promises to emit, that a consumer can generate
bindings from and pin a version of.

Contracts live in `schemas/`, one file per event type. Adding one means adding a file —
there is no Terraform change and no registration step to forget.

## What a contract is

An EventBridge contract is a standard OpenAPI 3 document with a fixed shape. The
`AWSEvent` component describes the envelope — the nine fields EventBridge puts around every
event — and carries two routing markers. A second component, referenced from `detail`,
describes the payload, which is the only part you design:

```jsonc
{
  "openapi": "3.0.0",
  "info": { "version": "1.0.0", "title": "OrderPlaced" },
  "paths": {},
  "components": {
    "schemas": {
      "AWSEvent": {
        "type": "object",
        "x-amazon-events-source": "com.example.orders",
        "x-amazon-events-detail-type": "Order Placed",
        "required": [
          "detail-type", "resources", "detail", "id",
          "source", "time", "region", "version", "account"
        ],
        "properties": {
          "detail": { "$ref": "#/components/schemas/OrderPlaced" }
          // ...the eight remaining envelope fields
        }
      },
      "OrderPlaced": {
        "type": "object",
        "required": ["orderId", "customerId", "currency", "totalAmount", "placedAt", "lines"],
        "properties": {
          "orderId": { "type": "string" },
          "channel": { "type": "string" }
          // ...
        }
      }
    }
  }
}
```

`schemas/order-placed.json` is that document in full, and
`schemas/payment-settled.json` is a second one showing an enumerated field.

## The rules that are enforced

Three properties are checked before anything is published, because each one is a silent
failure otherwise:

| Rule | Why it matters |
|---|---|
| Both `x-amazon-events-*` markers present | They are what ties the contract to real traffic |
| `info.version` present | A consumer pins a generated binding to a version |
| Every `$ref` resolves and every `required` entry exists | A contract that describes a field it does not declare cannot be relied on |

The first two are Terraform preconditions, so a contract missing either is rejected at plan
time. The third is checked by `tests/`, along with the derived-name uniqueness rule below.

## How a contract gets its name

The registered schema name is derived from the document, not the filename:

```
<x-amazon-events-source>@<x-amazon-events-detail-type with spaces removed>
```

so `com.example.orders` + `Order Placed` registers as `com.example.orders@OrderPlaced`.

This is deliberate and it is the same convention schema discovery uses. Renaming a file
therefore cannot silently detach a contract from the events it describes, and a published
contract lines up with its discovered counterpart instead of sitting beside it as a
near-duplicate. Two contracts that derive the same name are a collision the test suite
rejects, since the second would overwrite the first.

## Contracts and discovery run together

Discovery is enabled per bus and writes into the AWS-managed `discovered-schemas` registry.
Contracts are published into a separate curated registry. They are not alternatives:

- **Discovery describes what happened.** It infers a schema from traffic, so it sees
  everything actually on the bus, including events nobody declared.
- **A contract is an agreement.** It states what a producer commits to, which is what a
  consumer builds against.

Keeping both means the gap is visible. An event flowing with no published contract shows up
in the discovered registry and nowhere else, which is the signal that something is emitting
undeclared traffic. A contract with no matching discovered schema is the opposite signal: a
promise nobody is keeping.

## Evolving a contract

The archive retains events in their **original** shape, so a replay after a breaking change
replays the old shape. That single fact decides the rules:

| Change | Compatible? | What to do |
|---|---|---|
| Add an optional field | Yes | Bump the minor version |
| Add a value to an enum | Usually not | Consumers may switch exhaustively; treat as breaking unless you know otherwise |
| Make an optional field required | No | New detail type |
| Rename or remove a field | No | New detail type |
| Change a field's type | No | New detail type |

A breaking change is published as a **new detail type** rather than an edit to the existing
contract — `Order Placed v2`, or a name that reflects what actually changed. Run both for a
deprecation window, move consumers across, then retire the old one. Editing in place strands
every consumer pinned to the old version and makes any replay from before the edit
unparseable.

## Consuming a contract

Consumers generate bindings from the registry rather than hand-writing a type:

```bash
# What is published, and what discovery has inferred
aws schemas list-schemas --registry-name "$(terraform output -raw schema_registry_name)"
aws schemas list-schemas --registry-name discovered-schemas

# Fetch one contract at a pinned version
aws schemas describe-schema \
  --registry-name "$(terraform output -raw schema_registry_name)" \
  --schema-name 'com.example.orders@OrderPlaced' \
  --schema-version 1

# Generate bindings for a language
aws schemas get-code-binding-source \
  --registry-name "$(terraform output -raw schema_registry_name)" \
  --schema-name 'com.example.orders@OrderPlaced' \
  --language Java8 \
  bindings.zip
```

Pin the version. An unpinned binding regenerated after a minor bump is usually fine and
occasionally is not, and the failure lands at runtime in the consumer.

## Filtering on a contract

A rule may only filter on `detail` fields the contract actually declares. This is a
convention this repository adds, not a service rule, and it exists because the failure is
invisible: a rule keyed on a field that does not exist is valid JSON, is accepted by
EventBridge, and matches nothing forever.

```hcl
# Selects settled card and wallet payments. Both values are in the contract's enum,
# and `method` is a property the contract declares.
event_pattern = jsonencode({
  source        = ["com.example.payments"]
  "detail-type" = ["Payment Settled"]
  detail        = { method = ["card", "wallet"] }
})
```

`make patterns` checks every pattern in the tree against the published contracts on exactly
that basis, including the examples in the documentation. It runs on every push.

## Adding a contract

1. Write the document into `schemas/<event-name>.json`, kebab case after the event.
2. Set both markers and `info.version`.
3. Describe the payload in a component and `$ref` it from `detail`.
4. Run `make patterns` — the contract is picked up from disk with no registration step.
5. Commit. It is published on the next apply, and any rule filtering on it is now checked
   against it.
