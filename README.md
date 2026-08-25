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
| Queue-to-event bridging | Pipes that carry a queue into the backbone, filtering and enriching on the way |
| Synchronous enrichment | A function or express workflow that adds context before delivery |
| Execution logging | Per-pipe logs showing what was filtered, enriched, and rejected |
| Scheduled invocation | Recurring and one-time work on a clock, independent of any bus |
| Timezone-aware cron | Schedules that stay correct across a daylight-saving change |
| Invocation spreading | Flexible windows so a fleet of schedules does not arrive at once |
| Cross-account publishing | A narrowed resource policy saying who outside the account may publish |
| Cross-account forwarding | Rules that copy matching events onto a bus in another account or region |

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
| `pipes.tf` | Queue-sourced pipes, filtering, enrichment, and the one role they run as |
| `scheduler.tf` | Schedule groups, schedules, and the role their targets are invoked with |
| `cross-account.tf` | Inbound publish grants and outbound forwarding to remote buses |
| `outputs.tf` | Bus, archive, key, and schema identifiers for downstream configuration |
| `schemas/` | Published event contracts, one OpenAPI 3 document per event type |
| `tests/` | Offline checks over every event pattern and contract in the tree |

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
      detail        = { method = ["card", "wallet"] }
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

## Pipes

A rule fans one event out to destinations that never learn about each other. A pipe does
the opposite: it carries a single stream from one queue to one destination, and can filter
and enrich it on the way. Reach for a pipe when a queue needs to become part of the
backbone -- a legacy producer that only knows how to write to SQS, a buffer that has to be
drained in order, or a stream that needs a lookup before anyone can act on it.

```hcl
pipes = {
  "orders-to-core" = {
    source_queue_arn = "arn:aws:sqs:us-east-1:123456789012:legacy-order-intake"
    description      = "Lifts orders from the legacy intake queue onto the backbone."

    batch_size                         = 10
    maximum_batching_window_in_seconds = 5

    # Matched against the SQS envelope, so the payload sits under body.
    filter_patterns = [
      jsonencode({ body = { status = ["PLACED"] } }),
    ]

    # Whatever this returns replaces the payload. Returning nothing drops the message.
    enrichment = {
      type = "lambda"
      arn  = "arn:aws:lambda:us-east-1:123456789012:function:resolve-customer"
    }

    target = {
      type        = "bus"
      bus         = "platform-core"
      source      = "com.example.orders"
      detail_type = "Order Placed"
    }
  }

  "settlements-to-ledger" = {
    source_queue_arn = "arn:aws:sqs:us-east-1:123456789012:settlement-feed"
    desired_state    = "STOPPED"

    target = {
      type = "sfn"
      arn  = "arn:aws:states:us-east-1:123456789012:stateMachine:post-settlement"
    }
  }
}
```

### How a pipe differs from a rule

| | Rule | Pipe |
|---|---|---|
| Direction | EventBridge pushes to targets | The pipe polls its source |
| Shape | One source bus, many targets | One source queue, one destination |
| Authorization | Per target type: resource policy or assumed role | One role does everything |
| Backpressure | None; a slow target is retried then dropped | Work stays in the queue |
| Enrichment | Not available | A synchronous call between source and destination |
| Failure path | A dead-letter queue per rule | The source queue's own redrive policy |

### Two things that catch people out

**A filter is not an event pattern.** The message arrives wrapped in an SQS envelope, so a
pattern copied from a rule -- one keyed on `source`, `detail-type`, or `detail` -- matches
nothing at all, and every message is silently discarded. Filter on `body` instead. The
input surface rejects those three field names rather than letting a pipe drain a queue into
nowhere.

**A pipe has no dead-letter queue.** A pipe that cannot deliver simply does not delete the
message, so it returns to the source queue when the visibility timeout lapses. That makes
the *source queue's* `maxReceiveCount` the real failure path, and a source queue with no
redrive policy will retry a poison message forever. This configuration does not own the
source queue, so confirm the redrive policy on every ARN listed in the
`pipe_source_queue_arns` output.

### Rolling one out safely

A pipe begins consuming the moment it is created. Over a queue that already holds traffic,
ship it with `desired_state = "STOPPED"`, confirm the destination and the filter against the
execution log, then flip it to `RUNNING`. The `pipe_desired_states` output shows which
connectors are live.

Enrichment sharpens the same point. A Lambda enrichment is invoked synchronously and its
return value *replaces* the payload, so an enrichment that returns an empty response stops
the message there -- useful as a late filter for decisions a pattern cannot make, and easy
to mistake for lost data if it is not deliberate. A Step Functions enrichment must be an
EXPRESS workflow, because a Standard one cannot be called synchronously.

## Scheduled invocation

Some work has to happen at a time rather than because something happened. EventBridge only
accepts a schedule expression on the AWS-managed `default` bus, so a scheduled rule cannot
live on any of the buses declared here. Schedules are their own surface instead.

```hcl
schedule_groups = ["default", "billing"]

schedules = {
  "nightly-reconciliation" = {
    schedule_expression          = "cron(15 2 * * ? *)"
    schedule_expression_timezone = "Europe/Amsterdam"
    group                        = "billing"
    flexible_time_window_minutes = 15

    target = {
      type                  = "lambda"
      arn                   = "arn:aws:lambda:us-east-1:123456789012:function:reconcile-ledger"
      input                 = jsonencode({ mode = "full" })
      dead_letter_queue_arn = "arn:aws:sqs:us-east-1:123456789012:missed-invocations"
    }
  }

  "close-period" = {
    schedule_expression = "at(2026-10-01T03:00:00)"

    target = {
      type        = "bus"
      bus         = "platform-core"
      source      = "com.example.billing"
      detail_type = "Period Close Requested"
      input       = jsonencode({ period = "2026-09" })
    }
  }
}
```

### How a schedule differs from a rule

| | Rule | Schedule |
|---|---|---|
| Trigger | An event that already exists | A moment on a clock |
| Bus | Reads from a declared custom bus | Belongs to no bus at all |
| Shape | One pattern, many targets | One expression, one target |
| Authorization | Per target type: resource policy or assumed role | One role does everything |
| Replay | The archive holds the original event | Nothing is stored; a missed run is gone |
| Failure path | A dead-letter queue per rule | A dead-letter queue per schedule, if declared |

### Three things worth deciding deliberately

**Name the timezone, do not bake in the offset.** `schedule_expression_timezone` takes an
IANA zone such as `Europe/Amsterdam`, and a schedule written that way still runs at 02:15
local after the clocks change. A UTC expression chosen to line up with local time silently
drifts by an hour twice a year.

**Spread the load or accept the spike.** Everything written as `cron(0 * * * ? *)` fires in
the same second, and a downstream that would absorb the same work comfortably over ten
minutes falls over when it arrives at once. `flexible_time_window_minutes` opts into
spreading; leaving it unset is the right answer only when the job must run exactly on the
hour.

**Give anything that matters somewhere to fail.** A schedule retries inside its retry
window and then stops. Without a dead-letter queue the only remaining evidence is a metric,
so the `schedules_without_dead_letter_queue` output lists every schedule in that position:
fine for a cache refresh, not for closing a billing period.

A one-time `at()` schedule stays in place after it fires, in a completed state, so a group
accumulates them until they are removed. `start_date` and `end_date` bound a recurring
schedule and are rejected on a one-time one, which already names the moment it runs.

## Cross-account routing

Cross-account delivery is two independent halves, usually owned by two different teams.
Almost every failure comes from doing one of them and assuming the other was done too.

**Inbound** is a resource policy on the receiving bus. A bus accepts events only from its
own account until it says otherwise, so the account that owns the bus decides who may
publish to it:

```hcl
cross_account_access = {
  "platform-integration" = {
    account_ids          = ["222222222222"]
    allowed_sources      = ["com.partner.orders"]
    allowed_detail_types = ["Order Placed", "Order Cancelled"]
  }
}
```

Naming an account and stopping there lets that account put anything at all onto the bus,
including something shaped to match a rule it was never meant to trigger.
`allowed_sources` and `allowed_detail_types` narrow the grant to what the producer actually
publishes. A whole organization can be trusted with `organization_id` instead, but
`allow_rule_management` -- which lets a grantee decide where these events go next -- must
name its accounts explicitly, and confines each one to the rules it created.

**Outbound** is a rule whose target is a remote bus, plus a role EventBridge assumes to
publish there:

```hcl
cross_account_forwarding = {
  "orders-to-analytics" = {
    bus                   = "platform-core"
    event_pattern         = jsonencode({ source = ["com.example.orders"] })
    destination_bus_arns  = ["arn:aws:events:us-east-1:333333333333:event-bus/analytics-core"]
    dead_letter_queue_arn = "arn:aws:sqs:us-east-1:123456789012:forwarding-failures"
  }
}
```

Until the receiving account has done the inbound half, every delivery is refused. That
refusal is invisible without a queue, which is why
`cross_account_forwarding_without_dead_letter_queue` reports any route lacking one, and why
a new route is worth shipping with `state = "DISABLED"` and enabling once the far side is
confirmed.

Two properties to design around. The receiving bus sees the event with the **sending**
account's id in the `account` field while `source` and `detail-type` survive unchanged, so
a consumer that needs the origin should read `account` rather than assume `source` encodes
it. And a single hop is the pattern to aim for: forwarding an event that was itself
forwarded is hard to reason about, and a cycle between two buses sustains itself and bills
on every pass. A rule forwarding to a bus this configuration creates is rejected outright;
a longer cycle is a review question rather than a machine-checkable one.

## Event contracts

Files under `schemas/` are the source of truth for what a producer promises to emit. Each
one is a standard EventBridge OpenAPI 3 document whose `AWSEvent` component carries the
`x-amazon-events-source` and `x-amazon-events-detail-type` markers. The registered schema
name is derived from those two markers rather than from the filename, so renaming a file
cannot silently detach a contract from the events it describes.

Adding a contract means adding a file. Discovery stays enabled alongside it so that an
event flowing without a published contract is visible rather than invisible.

## Validation

An event pattern is the one part of this configuration that fails silently. A rule with a
wrong pattern is created successfully, keeps its targets, reports healthy, and never
delivers anything, because "matched nothing" and "working normally" look identical from
outside. Terraform can confirm a pattern parses as JSON and nothing beyond that.

`tests/` covers what comes after: the matching semantics that decide whether a pattern
selects an event, the structural rules the service enforces, and a set of conventions this
repository adds -- a pattern keys only on real envelope fields, every rule constrains
`source`, and a rule may only filter on `detail` fields its contract actually declares.
Every example in this README is checked against the published contracts on that basis.

```bash
pip install -r tests/requirements.txt
pytest tests -q                       # the full suite
python3 tests/lint_event_patterns.py  # pattern and contract lint on its own
```

Nothing here reads credentials or calls AWS. Contracts and examples are discovered from
disk, so a new one is covered without being registered anywhere.

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
- **Make the live surface visible.** A connector that drains a queue, a target with nowhere
  to send a failure, and a pipe carrying every message unfiltered are each reported as an
  output rather than left to be discovered during an incident.
- **One clock, one owner.** Recurring work is declared here alongside the routing it
  triggers, so the schedule, its permissions, and its failure path are reviewed together
  rather than living in whatever service happened to own a cron entry.
- **Placeholders only.** Account identifiers, ARNs, and domain names in this repository are
  documentation examples.
