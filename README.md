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
| Pattern-matched routing | Rules that filter a bus and fan out to typed destinations |
| Typed targets | Lambda, SQS, and Step Functions destinations, each authorized correctly |
| Undeliverable-event capture | A dead-letter queue per rule, scoped so its contents are unambiguous |

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
| `rules.tf` | Pattern rules, typed targets, target authorization, dead-letter queues |
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

## Routing

A rule filters one bus and fans the matching events out to destinations that never learn
about each other. Adding a consumer means adding a target here, not changing the producer.

```hcl
event_rules = {
  "order-placed" = {
    bus           = "platform-core"
    description   = "Fans a placed order out to fulfilment and to the analytics buffer."
    event_pattern = jsonencode({
      source        = ["com.example.orders"]
      "detail-type" = ["Order Placed"]
    })

    targets = {
      "fulfilment" = {
        type = "sfn"
        arn  = "arn:aws:states:us-east-1:123456789012:stateMachine:fulfil-order"
      }

      "analytics-buffer" = {
        type                = "sqs"
        arn                 = "arn:aws:sqs:us-east-1:123456789012:analytics-ingest"
        manage_queue_policy = true

        input_transformer = {
          input_paths = {
            orderId = "$.detail.orderId"
            placed  = "$.time"
          }
          input_template = "{\"order\": <orderId>, \"placedAt\": <placed>, \"rule\": <aws.events.rule-name>}"
        }
      }
    }
  }

  "payment-settled" = {
    bus           = "platform-core"
    event_pattern = jsonencode({
      source        = ["com.example.payments"]
      "detail-type" = ["Payment Settled"]
      detail        = { status = ["SETTLED"] }
    })

    targets = {
      "ledger" = {
        type = "lambda"
        arn  = "arn:aws:lambda:us-east-1:123456789012:function:post-to-ledger"

        maximum_event_age_in_seconds = 21600
        maximum_retry_attempts       = 20
      }
    }
  }
}
```

### How each target type is authorized

The asymmetry here is the part most worth knowing, because getting it wrong produces a
rule that looks correctly configured and silently never delivers.

| Target type | How EventBridge is allowed to deliver | What this configuration creates |
|---|---|---|
| `lambda` | Resource policy on the function | An invoke permission scoped to the calling rule |
| `sqs` | Resource policy on the queue | A queue policy, only when `manage_queue_policy` is set |
| `sfn` | An IAM role EventBridge assumes | One role, scoped to exactly the declared state machines |

A queue policy replaces whatever policy the queue already carries, so it is opt-in: a
queue owned by another stack should keep its own policy and add a statement there instead.
Declaring `role_arn` on a Lambda or SQS target is rejected rather than ignored.

### When delivery fails

Every rule is given its own dead-letter queue unless that is turned off, and a target may
name a different queue if failures are already collected centrally. Two defaults are set
deliberately:

- **Retry window of one hour**, against a service default of 24. A broken consumer should
  surface in a dead-letter queue while the deployment that broke it is still fresh. Raise
  it per target for a destination with long maintenance windows.
- **One queue per rule, not per target.** During an incident the useful question is what a
  route failed to deliver, and per-target queues fragment that answer across destinations
  that usually fail together.

The queue policy admits exactly one rule, so the contents of a dead-letter queue never
need to be attributed. Any target left with nowhere to send a failure is listed in the
`targets_without_dead_letter_queue` output rather than being quietly accepted.

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
- **Authorize precisely.** Every delivery grant names the one rule it exists for, and
  every invocation role names the exact destinations it may reach.
- **Placeholders only.** Account identifiers, ARNs, and domain names in this repository are
  documentation examples.
