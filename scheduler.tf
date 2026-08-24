# Clock-driven invocation: the work that has to happen at a time, rather than in response
# to something that happened.
#
# A schedule is not a rule with a timer, and the differences decide where a job belongs:
#
#   1. A rule reacts to an event that already exists. A schedule creates the moment. That
#      is why a schedule has no event pattern and no archive: there is nothing to match
#      against and nothing to replay.
#
#   2. EventBridge accepts a schedule expression only on the AWS-managed default bus, so a
#      scheduled rule cannot live on any of the custom buses declared here. Scheduler is
#      the surface without that restriction, and it also brings one-minute granularity,
#      timezone-aware cron that survives a daylight-saving change, and one-time at()
#      expressions.
#
#   3. Authorization is uniform, as it is for a pipe. There is no resource-policy path at
#      all: every target is invoked through the role the schedule assumes, so a Lambda
#      function needs no invoke permission attached to it and a queue needs no queue
#      policy. Everything is one role, scoped to exactly the declared destinations.
#
#   4. A missed invocation is gone. A failed delivery is retried inside its retry window
#      and then written to the dead-letter queue; with no queue configured, the only
#      remaining evidence is a metric. A schedule whose work matters gets a queue, and the
#      ones that do not have one are reported rather than silently accepted.
#
#   5. Flexible time windows exist because schedules cluster. Everything written as
#      cron(0 * * * ? *) fires in the same second of the same minute, and a downstream
#      that would comfortably absorb the same work spread over ten minutes falls over when
#      it arrives at once. Spreading is opt-in here rather than assumed, because a job that
#      must run exactly on the hour has to be able to say so.
#
# The stored target payload is encrypted with the bus key by default, so a schedule
# carrying a request body is protected the same way an event carrying one is.

locals {
  schedule_group_names = { for key, group in aws_scheduler_schedule_group.this : key => group.name }

  # An unresolvable bus key is left out of the role policy and reported by the precondition
  # on the schedule itself, which produces a readable error rather than an index failure.
  schedule_target_bus_keys = { for key, schedule in var.schedules : key => schedule.target.bus if schedule.target.type == "bus" }

  schedule_target_arns = {
    for key, schedule in var.schedules : key => (
      schedule.target.type == "bus"
      ? lookup(local.bus_arns_by_key, schedule.target.bus == null ? "-unset-" : schedule.target.bus, "unresolved-event-bus")
      : schedule.target.arn
    )
  }

  # Each list names exactly the resources one statement on the role exists for, so adding a
  # destination is a change to this configuration rather than a permission that was already
  # wide enough to cover it.
  schedule_lambda_arns = distinct([for schedule in values(var.schedules) : schedule.target.arn if schedule.target.type == "lambda"])
  schedule_sqs_arns    = distinct([for schedule in values(var.schedules) : schedule.target.arn if schedule.target.type == "sqs"])
  schedule_sfn_arns    = distinct([for schedule in values(var.schedules) : schedule.target.arn if schedule.target.type == "sfn"])

  schedule_bus_arns = distinct([
    for bus_key in values(local.schedule_target_bus_keys) : local.bus_arns_by_key[bus_key]
    if contains(keys(local.bus_arns_by_key), bus_key)
  ])

  schedule_dead_letter_arns = distinct([
    for schedule in values(var.schedules) : schedule.target.dead_letter_queue_arn
    if schedule.target.dead_letter_queue_arn != null
  ])

  # Surfaced rather than enforced. A schedule that only refreshes a cache does not need
  # somewhere to record a missed run; one that closes a billing period does.
  schedules_without_dead_letter = sort([
    for key, schedule in var.schedules : key if schedule.target.dead_letter_queue_arn == null
  ])

  create_schedule_role = length(var.schedules) > 0 && var.schedule_role_arn == null
  schedule_role_arn    = var.schedule_role_arn != null ? var.schedule_role_arn : one(aws_iam_role.scheduler[*].arn)

  # Named once and consumed both by the role itself and by the key-policy grant that
  # admits it, so the two derivations cannot drift apart.
  scheduler_role_name = "${var.name_prefix}-scheduler"

  schedule_key_arn = var.schedule_kms_key_arn != null ? var.schedule_kms_key_arn : local.bus_key_arn

  # Derived from inputs alone. The bus key policy consults this to decide whether to admit
  # the schedule role, and it must not depend on the role it is admitting.
  grant_scheduler_key_use = local.create_key && var.schedule_kms_key_arn == null && length(var.schedules) > 0

  scheduler_principal_arn = (
    var.schedule_role_arn != null
    ? var.schedule_role_arn
    : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.scheduler_role_name}"
  )

  schedule_kms_key_arns = distinct(concat(
    local.schedule_key_arn != null ? [local.schedule_key_arn] : [],
    flatten([for schedule in values(var.schedules) : schedule.additional_kms_key_arns])
  ))
}

# --------------------------------------------------------------------------------------
# Groups
# --------------------------------------------------------------------------------------

# Groups are the unit schedules are tagged and monitored by. Splitting them by owning team
# or by blast radius answers "whose schedules are failing"; splitting them by cadence does
# not answer anything anyone asks during an incident.
resource "aws_scheduler_schedule_group" "this" {
  for_each = var.schedule_groups

  name = "${var.name_prefix}-${each.key}"

  tags = {
    Name = "${var.name_prefix}-${each.key}"
  }

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-${each.key}") <= 64
      error_message = "The prefixed schedule group name for ${each.key} exceeds the 64-character limit."
    }
  }
}

# --------------------------------------------------------------------------------------
# Schedules
# --------------------------------------------------------------------------------------

resource "aws_scheduler_schedule" "this" {
  for_each = var.schedules

  name        = "${var.name_prefix}-${each.key}"
  group_name  = lookup(local.schedule_group_names, each.value.group, "unresolved-schedule-group")
  description = coalesce(each.value.description, "Invokes the declared ${each.value.target.type} target on ${each.value.schedule_expression}.")
  state       = each.value.state

  schedule_expression          = each.value.schedule_expression
  schedule_expression_timezone = each.value.schedule_expression_timezone
  start_date                   = each.value.start_date
  end_date                     = each.value.end_date

  kms_key_arn = local.schedule_key_arn

  # OFF means the invocation lands on the second the expression names. FLEXIBLE spreads it
  # across the window, which is how a set of hourly schedules stops arriving together.
  flexible_time_window {
    mode                      = each.value.flexible_time_window_minutes == null ? "OFF" : "FLEXIBLE"
    maximum_window_in_minutes = each.value.flexible_time_window_minutes
  }

  target {
    arn      = local.schedule_target_arns[each.key]
    role_arn = local.schedule_role_arn
    input    = each.value.target.input

    # Always emitted so the effective policy is visible in the plan rather than inherited
    # from a service default. An explicit null check rather than coalesce, because zero
    # retries is a legitimate setting for a job that must not run twice.
    retry_policy {
      maximum_event_age_in_seconds = each.value.target.maximum_event_age_in_seconds != null ? each.value.target.maximum_event_age_in_seconds : var.default_target_retry_policy.maximum_event_age_in_seconds
      maximum_retry_attempts       = each.value.target.maximum_retry_attempts != null ? each.value.target.maximum_retry_attempts : var.default_target_retry_policy.maximum_retry_attempts
    }

    dynamic "dead_letter_config" {
      for_each = each.value.target.dead_letter_queue_arn == null ? toset([]) : toset([each.value.target.dead_letter_queue_arn])

      content {
        arn = dead_letter_config.value
      }
    }

    dynamic "sqs_parameters" {
      for_each = each.value.target.message_group_id == null ? toset([]) : toset([each.value.target.message_group_id])

      content {
        message_group_id = sqs_parameters.value
      }
    }

    # A bus target publishes a NEW event rather than forwarding one, so it has to supply
    # the source and detail type a consumer will match on.
    dynamic "eventbridge_parameters" {
      for_each = each.value.target.type == "bus" ? toset(["enabled"]) : toset([])

      content {
        detail_type = each.value.target.detail_type
        source      = each.value.target.source
      }
    }
  }

  lifecycle {
    precondition {
      condition     = contains(var.schedule_groups, each.value.group)
      error_message = "Schedule ${each.key} belongs to group ${each.value.group}, which is not declared in schedule_groups. Declare the group or point the schedule at an existing one."
    }

    precondition {
      condition     = each.value.target.type != "bus" || contains(keys(var.event_buses), each.value.target.bus)
      error_message = "Schedule ${each.key} targets bus ${coalesce(each.value.target.bus, "(unset)")}, which is not declared in event_buses."
    }

    precondition {
      condition     = length("${var.name_prefix}-${each.key}") <= 64
      error_message = "The prefixed schedule name for ${each.key} exceeds the 64-character limit."
    }
  }
}

# --------------------------------------------------------------------------------------
# Execution role
# --------------------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  count = local.create_schedule_role ? 1 : 0

  statement {
    sid     = "AllowSchedulerToAssumeTheExecutionRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Without this pairing, any account's Scheduler could assume the role if it ever learned
    # the name. The schedule ARN carries its group, so the wildcard sits on the group
    # segment and the name segment stays pinned to this configuration's prefix.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule/*/${var.name_prefix}-*"]
    }
  }
}

data "aws_iam_policy_document" "scheduler" {
  count = local.create_schedule_role ? 1 : 0

  dynamic "statement" {
    for_each = length(local.schedule_lambda_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "InvokeDeclaredFunctions"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = local.schedule_lambda_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.schedule_sqs_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "SendToDeclaredQueues"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = local.schedule_sqs_arns
    }
  }

  # Scheduler starts a Standard workflow and does not wait for it, so the express-only
  # synchronous action is deliberately absent.
  dynamic "statement" {
    for_each = length(local.schedule_sfn_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "StartDeclaredStateMachines"
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = local.schedule_sfn_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.schedule_bus_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "PublishToDeclaredBuses"
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = local.schedule_bus_arns
    }
  }

  # Writing a missed invocation to its dead-letter queue is a separate grant from writing
  # to a queue that is itself a target, and a schedule may have one without the other.
  dynamic "statement" {
    for_each = length(local.schedule_dead_letter_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "SendToDeclaredDeadLetterQueues"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = local.schedule_dead_letter_arns
    }
  }

  # The role reads its own encrypted payload and writes to encrypted destinations as
  # itself, so it needs key use directly rather than inheriting it from a service
  # principal.
  dynamic "statement" {
    for_each = length(local.schedule_kms_key_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid    = "UseDeclaredKeys"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
      ]

      resources = local.schedule_kms_key_arns
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = local.create_schedule_role ? 1 : 0

  name                 = local.scheduler_role_name
  description          = "Assumed by EventBridge Scheduler to invoke the targets declared for this configuration's schedules."
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume[0].json
  max_session_duration = 3600

  tags = {
    Name = local.scheduler_role_name
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.create_schedule_role ? 1 : 0

  name   = "invoke-schedule-targets"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler[0].json
}
