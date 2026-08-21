# aws-eventbridge-automation

Terraform for an event-driven backbone on Amazon EventBridge: custom event buses with
durable archives, published event contracts, pattern-matched routing, managed pipes,
scheduled invocations, and cross-account delivery.

The design goal is that a producer publishes an event and never learns who consumes it.
Routing, retention, and access are declared as configuration in this repository, so adding
a consumer is a change here rather than a change inside the producing service.

## Capabilities

| Capability | What it gives you |
|---|---|
| Custom event buses | Traffic separated by trust boundary instead of one shared default bus |
| Durable archive | Every accepted event retained for a declared window and replayable |
| Event contracts | Published, versioned schemas so consumers code against an agreement |
| Schema discovery | Automatic inference of what is actually flowing, to catch undeclared events |
| Encryption at rest | Bus and archive contents encrypted with a customer managed key |

## Why separate buses

The AWS-managed `default` bus receives service events from the whole account and cannot be
given a narrow resource policy. Splitting traffic across purpose-built buses means an
access grant, an archive retention period, and a failure blast radius can each be reasoned
about for one class of traffic:

- **core** — domain events published by first-party services. Trusted producers, shorter
  retention, schema discovery on so drift is visible.
- **integration** — traffic exchanged with partners and vendors. Untrusted producers,
  longer retention because disputes surface late, and a narrower set of consumers.

## Repository layout

| Path | Purpose |
|---|---|
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | Regional provider with tags applied to every resource |
| `variables.tf` | Input surface, validated at plan time |
| `event-bus.tf` | Custom buses, archives, encryption key, schema registry and discovery |
| `outputs.tf` | Bus, archive, key, and schema identifiers for downstream configuration |
| `schemas/` | Published event contracts, one OpenAPI 3 document per event type |

## Getting started

```hcl
module "event_backbone" {
  source = "github.com/<your-github-org>/aws-eventbridge-automation?ref=v1.0.0"

  aws_region  = "us-east-1"
  name_prefix = "acme"

  event_buses = {
    "platform-core" = {
      description              = "Domain events published by first-party services."
      schema_discovery_enabled = true

      archive = {
        retention_days = 90
      }
    }

    "platform-integration" = {
      description           = "Events exchanged with partner systems."
      dead_letter_queue_arn = "arn:aws:sqs:us-east-1:123456789012:acme-bus-dlq"

      archive = {
        retention_days = 365
        event_pattern  = "{\"source\":[{\"prefix\":\"partner.\"}]}"
      }
    }
  }
}
```

Every value above is a placeholder. Nothing in this repository is applied against an
account by the repository itself; it ships as templates for you to plan and review.

## Event contracts

Files under `schemas/` are the source of truth for what a producer promises to emit. Each
one is a standard EventBridge OpenAPI 3 document whose `AWSEvent` component carries the
`x-amazon-events-source` and `x-amazon-events-detail-type` markers. The registered schema
name is derived from those two markers rather than from the filename, so renaming a file
cannot silently detach a contract from the events it describes.

Adding a contract means adding a file. Discovery stays enabled alongside it so that an
event flowing without a published contract is visible rather than invisible.

## Design principles

- **Configuration, not code.** Buses, retention, and routing are declared data. A new
  consumer is a configuration change.
- **Fail at plan time.** Inputs carry validation and resources carry preconditions, so a
  malformed event pattern or an impossible combination is rejected before anything is
  created.
- **Encrypted by default.** A customer managed key is created unless one is supplied, and
  both the bus and its archive use it.
- **Placeholders only.** Account identifiers, ARNs, and domain names in this repository are
  documentation examples.
