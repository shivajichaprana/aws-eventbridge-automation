# Pattern-matched routing: which events leave a bus, where they go, and what happens to
# the ones that never arrive.
#
# A rule is a filter plus a list of destinations. The parts worth understanding before
# changing anything here are the ones that are not symmetric:
#
#   1. Target types are authorized differently. EventBridge invokes a Lambda function and
#      writes to an SQS queue using a resource policy attached to the TARGET, but it starts
#      a Step Functions execution using an IAM role it assumes. So a Lambda target grows an
#      aws_lambda_permission, an SQS target may grow a queue policy, and a state machine
#      target grows a role entry. Declaring a role on a Lambda or SQS target is rejected
#      rather than silently ignored, because that mistake otherwise looks like it worked.
#
#   2. Delivery failure and match failure are different events. A rule that matches nothing
#      is silent by design. A rule that matches and then fails to deliver is a lost event,
#      which is why every rule gets a dead-letter queue unless one is deliberately turned
#      off, and why the retry window is shortened from the service default.
#
#   3. Retention of a failed event is bounded by the retry policy, not by the queue. The
#      AWS default retries for 24 hours, so a broken consumer takes a day to show up in the
#      dead-letter queue. The default here is an hour, which trades a little resilience to
#      long outages for a much faster signal. Raise it per target where the destination is
#      known to have long maintenance windows.
#
# Rules attach to the custom buses declared alongside them. A schedule expression is not
# accepted here: EventBridge only supports scheduled rules on the AWS-managed default bus,
# and recurring invocation is handled by the scheduler surface instead.

locals {
  # Referencing the bus resource keeps the dependency implicit while the lookup default
  # keeps an unknown bus key from failing as an index error. The readable explanation is
  # produced by the precondition on the rule itself.
  bus_names_by_key = { for key, bus in aws_cloudwatch_event_bus.this : key => bus.name }

  # One flat map of every rule/target pair, keyed "<rule>/<target>". Terraform needs a flat
  # collection to drive for_each, and the composite key keeps target identifiers unique
  # across rules that reuse the same target name.
  rule_targets = merge([
    for rule_key, rule in var.event_rules : {
      for target_key, target in rule.targets :
      "${rule_key}/${target_key}" => merge(target, {
        rule_key   = rule_key
        target_key = target_key
      })
    }
  ]...)

  lambda_targets = {
    for key, target in local.rule_targets : key => target
    if target.type == "lambda"
  }

  # Opt-in only. aws_sqs_queue_policy REPLACES whatever policy the queue already carries,
  # so a module that took this on by default would silently revoke every other producer's
  # access to a queue it does not own.
  sqs_policy_targets = {
    for key, target in local.rule_targets : key => target
    if target.type == "sqs" && target.manage_queue_policy
  }

  state_machine_targets = {
    for key, target in local.rule_targets : key => target
    if target.type == "sfn"
  }

  # The invocation role is scoped to exactly the state machines that are declared, so
  # adding a destination is a change to this configuration rather than a permission that
  # was already broad enough to cover it.
  state_machine_arns = distinct([for target in values(local.state_machine_targets) : target.arn])
  create_states_role = length(local.state_machine_targets) > 0 && var.step_functions_invocation_role_arn == null
  states_role_arn    = var.step_functions_invocation_role_arn != null ? var.step_functions_invocation_role_arn : one(aws_iam_role.event_target_states[*].arn)

  managed_dlq_rules = var.create_rule_dead_letter_queues ? var.event_rules : {}
  managed_dlq_arns  = { for key, queue in aws_sqs_queue.rule_dlq : key => queue.arn }

  # An explicit per-target queue wins over the managed per-rule queue, so a caller who
  # already routes undeliverable events somewhere central is not given a second place to
  # look.
  # SQS exposes a queue at a URL that is fully determined by its ARN, so the address can be
  # derived rather than read back through a data source. Planning this configuration then
  # never depends on a queue that another stack may not have created yet.
  sqs_target_queue_urls = {
    for key, target in local.sqs_policy_targets :
    key => "https://sqs.${element(split(":", target.arn), 3)}.${data.aws_partition.current.dns_suffix}/${element(split(":", target.arn), 4)}/${element(split(":", target.arn), 5)}"
  }

  target_dead_letter_arns = {
    for key, target in local.rule_targets : key => (
      target.dead_letter_queue_arn != null
      ? target.dead_letter_queue_arn
      : lookup(local.managed_dlq_arns, target.rule_key, null)
    )
  }

  # Surfaced as an output rather than enforced. A target with nowhere to send a failed
  # delivery is a legitimate choice for a destination that is itself a durable queue, but
  # it should be a visible one.
  targets_without_dead_letter = sort([
    for key, arn in local.target_dead_letter_arns : key if arn == null
  ])
}

# --------------------------------------------------------------------------------------
# Undeliverable-event queues
# --------------------------------------------------------------------------------------

# One queue per rule rather than one per target: the useful question during an incident is
# "what did this route fail to deliver", and a per-target queue fragments that answer
# across destinations that usually fail together.
resource "aws_sqs_queue" "rule_dlq" {
  for_each = local.managed_dlq_rules

  name                      = "${var.name_prefix}-${each.key}-dlq"
  message_retention_seconds = var.dead_letter_queue_retention_seconds

  # The bus key protects the queue too, so a failed event is no less protected than the
  # same event was in flight. When no customer managed key resolves, service-managed
  # encryption is used rather than leaving the queue unencrypted.
  kms_master_key_id                 = local.bus_key_arn
  kms_data_key_reuse_period_seconds = local.bus_key_arn != null ? 300 : null
  sqs_managed_sse_enabled           = local.bus_key_arn == null ? true : null

  tags = {
    Name = "${var.name_prefix}-${each.key}-dlq"
  }

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-${each.key}-dlq") <= 80
      error_message = "The dead-letter queue name for rule ${each.key} exceeds the 80-character SQS limit. Shorten name_prefix or the rule key."
    }
  }
}

data "aws_iam_policy_document" "rule_dlq" {
  for_each = local.managed_dlq_rules

  # Scoped to the one rule that owns the queue. A second rule cannot write here without a
  # configuration change, which keeps the contents of the queue unambiguous.
  statement {
    sid    = "AllowOwningRuleToSendUndeliverableEvents"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.rule_dlq[each.key].arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.this[each.key].arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.rule_dlq[each.key].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "rule_dlq" {
  for_each = local.managed_dlq_rules

  queue_url = aws_sqs_queue.rule_dlq[each.key].url
  policy    = data.aws_iam_policy_document.rule_dlq[each.key].json
}

# --------------------------------------------------------------------------------------
# Rules
# --------------------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "this" {
  for_each = var.event_rules

  name           = "${var.name_prefix}-${each.key}"
  description    = coalesce(each.value.description, "Routes matching events off the ${each.value.bus} bus.")
  event_bus_name = lookup(local.bus_names_by_key, each.value.bus, "unresolved-event-bus")
  event_pattern  = each.value.event_pattern
  state          = each.value.state

  tags = {
    Name = "${var.name_prefix}-${each.key}"
  }

  lifecycle {
    precondition {
      condition     = contains(keys(var.event_buses), each.value.bus)
      error_message = "Rule ${each.key} attaches to bus ${each.value.bus}, which is not declared in event_buses. Declare the bus or point the rule at an existing key."
    }

    precondition {
      condition     = length("${var.name_prefix}-${each.key}") <= 64
      error_message = "The prefixed rule name for ${each.key} exceeds the 64-character limit."
    }
  }
}

# --------------------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------------------

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.rule_targets

  rule           = aws_cloudwatch_event_rule.this[each.value.rule_key].name
  event_bus_name = aws_cloudwatch_event_rule.this[each.value.rule_key].event_bus_name
  target_id      = each.value.target_key
  arn            = each.value.arn

  # A role is only meaningful for target types EventBridge invokes by assuming one. The
  # input surface rejects a role on the other types, so this stays null for them.
  role_arn = each.value.type == "sfn" ? (each.value.role_arn != null ? each.value.role_arn : local.states_role_arn) : null

  # At most one of these three is set, enforced on the way in.
  input      = each.value.input
  input_path = each.value.input_path

  dynamic "input_transformer" {
    for_each = each.value.input_transformer == null ? toset([]) : toset([each.value.input_transformer])

    content {
      input_paths    = length(input_transformer.value.input_paths) > 0 ? input_transformer.value.input_paths : null
      input_template = input_transformer.value.input_template
    }
  }

  # A FIFO queue rejects a message with no group id, so the pairing is enforced in both
  # directions before anything is created.
  dynamic "sqs_target" {
    for_each = each.value.message_group_id == null ? toset([]) : toset([each.value.message_group_id])

    content {
      message_group_id = sqs_target.value
    }
  }

  # Always emitted so the effective policy is visible in the plan rather than inherited
  # from a service default that differs from the one documented here.
  # An explicit null check rather than coalesce, because zero retries is a legitimate
  # setting for an idempotent destination and must not be mistaken for "unset".
  retry_policy {
    maximum_event_age_in_seconds = each.value.maximum_event_age_in_seconds != null ? each.value.maximum_event_age_in_seconds : var.default_target_retry_policy.maximum_event_age_in_seconds
    maximum_retry_attempts       = each.value.maximum_retry_attempts != null ? each.value.maximum_retry_attempts : var.default_target_retry_policy.maximum_retry_attempts
  }

  dynamic "dead_letter_config" {
    for_each = local.target_dead_letter_arns[each.key] == null ? toset([]) : toset([local.target_dead_letter_arns[each.key]])

    content {
      arn = dead_letter_config.value
    }
  }
}

# --------------------------------------------------------------------------------------
# Target authorization
# --------------------------------------------------------------------------------------

# Lambda is invoked through a resource policy on the function, scoped to the exact rule
# that may call it. Turning this off is for the case where the function's policy is owned
# by the team that owns the function.
resource "aws_lambda_permission" "target" {
  for_each = var.manage_lambda_target_permissions ? local.lambda_targets : {}

  statement_id  = "AllowEventBridge-${replace(replace(each.key, "/", "-"), ".", "-")}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.this[each.value.rule_key].arn

  lifecycle {
    precondition {
      condition     = length("AllowEventBridge-${replace(replace(each.key, "/", "-"), ".", "-")}") <= 100
      error_message = "The generated Lambda permission statement id for ${each.key} exceeds the 100-character limit. Shorten the rule or target key."
    }
  }
}

data "aws_iam_policy_document" "sqs_target" {
  for_each = local.sqs_policy_targets

  statement {
    sid    = "AllowOwningRuleToSendEvents"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [each.value.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.this[each.value.rule_key].arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [each.value.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "sqs_target" {
  for_each = local.sqs_policy_targets

  queue_url = local.sqs_target_queue_urls[each.key]
  policy    = data.aws_iam_policy_document.sqs_target[each.key].json
}

data "aws_iam_policy_document" "event_target_states_assume" {
  count = local.create_states_role ? 1 : 0

  statement {
    sid     = "AllowEventBridgeToAssumeTheInvocationRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    # Without this, any account's EventBridge could assume the role if it ever learned the
    # name. The pairing of source account and source ARN is the confused-deputy guard.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${var.name_prefix}-*"]
    }
  }
}

data "aws_iam_policy_document" "event_target_states" {
  count = local.create_states_role ? 1 : 0

  statement {
    sid       = "StartDeclaredStateMachines"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = local.state_machine_arns
  }
}

resource "aws_iam_role" "event_target_states" {
  count = local.create_states_role ? 1 : 0

  name                 = "${var.name_prefix}-event-target-states"
  description          = "Assumed by EventBridge to start the state machines declared as rule targets."
  assume_role_policy   = data.aws_iam_policy_document.event_target_states_assume[0].json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-event-target-states"
  }
}

resource "aws_iam_role_policy" "event_target_states" {
  count = local.create_states_role ? 1 : 0

  name   = "start-state-machines"
  role   = aws_iam_role.event_target_states[0].id
  policy = data.aws_iam_policy_document.event_target_states[0].json
}
