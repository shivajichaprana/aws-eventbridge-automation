# Point-to-point connectors between a queue and a single destination, with optional
# filtering and enrichment in between.
#
# A pipe is not a smaller rule, and the differences are what make it the right tool for a
# different job:
#
#   1. A rule is pushed to; a pipe pulls. EventBridge polls the source queue on the pipe's
#      behalf, so an unavailable destination applies backpressure and the work stays in the
#      queue instead of being retried against a dead endpoint and eventually dropped.
#
#   2. One source, one destination. A rule fans out to targets that never learn about each
#      other. A pipe carries a single stream, which is what lets it offer ordering,
#      batching, and a synchronous enrichment step that a fan-out cannot.
#
#   3. Authorization is uniform. A rule authorizes each target type differently, some
#      through a resource policy on the target and some through an assumed role. A pipe
#      does everything with its own role: it reads the source, calls the enrichment, and
#      writes the destination as itself. So there are no permissions to attach to a Lambda
#      function or a queue here, only statements on one role.
#
#   4. There is no dead-letter configuration. A rule that cannot deliver sends the event to
#      a dead-letter queue. A pipe that cannot deliver does not delete the message, so it
#      returns to the source queue and the SOURCE QUEUE'S OWN redrive policy is the failure
#      path. A pipe over a queue with no redrive policy will retry a poison message
#      indefinitely; set maxReceiveCount on the source queue, which this configuration
#      deliberately does not own.
#
#   5. A filter is matched against the SQS envelope, not against a bus event. The message
#      arrives wrapped, with the payload under `body`, so a pattern copied from a rule
#      matches nothing at all. The input surface rejects the three field names that make
#      that mistake recognisable.
#
# A pipe starts consuming as soon as it is created. Ship one over a queue that already has
# traffic as STOPPED, confirm the destination, then start it.

locals {
  bus_arns_by_key = { for key, bus in aws_cloudwatch_event_bus.this : key => bus.arn }

  # A pipe with logging off gets no log group and no log configuration block, rather than
  # an empty log group nobody reads.
  logged_pipes = { for key, pipe in var.pipes : key => pipe if pipe.log_level != "OFF" }

  pipe_log_key_arn = var.pipe_log_kms_key_arn != null ? var.pipe_log_kms_key_arn : local.bus_key_arn

  # Derived from inputs alone. The key policy consults this to decide whether to grant
  # CloudWatch Logs use of the bus key, and it must not depend on the log groups that the
  # key will go on to encrypt.
  grant_logs_key_use = local.create_key && var.pipe_log_kms_key_arn == null && length({
    for key, pipe in var.pipes : key => pipe if pipe.log_level != "OFF"
  }) > 0

  create_pipes_role = length(var.pipes) > 0 && var.pipe_role_arn == null
  pipes_role_arn    = var.pipe_role_arn != null ? var.pipe_role_arn : one(aws_iam_role.pipes[*].arn)

  # A Lambda destination is invoked synchronously by default so that a failure propagates
  # back to the pipe and the batch returns to the queue. Fire-and-forget would have the
  # pipe delete a message it never confirmed was handled. A state machine defaults the
  # other way, because fire-and-forget is the only mode a Standard workflow supports.
  target_invocation_types = {
    for key, pipe in var.pipes : key => (
      pipe.target.invocation_type != null
      ? pipe.target.invocation_type
      : (pipe.target.type == "lambda" ? "REQUEST_RESPONSE" : (pipe.target.type == "sfn" ? "FIRE_AND_FORGET" : null))
    )
  }

  # Each of these lists names exactly the resources one statement on the role exists for,
  # so adding a destination is a change to this configuration rather than a permission that
  # was already wide enough to cover it.
  pipe_source_queue_arns = distinct([for pipe in values(var.pipes) : pipe.source_queue_arn])

  pipe_enrichments = { for key, pipe in var.pipes : key => pipe.enrichment if pipe.enrichment != null }

  enrichment_lambda_arns = distinct([for enrichment in values(local.pipe_enrichments) : enrichment.arn if enrichment.type == "lambda"])
  enrichment_sfn_arns    = distinct([for enrichment in values(local.pipe_enrichments) : enrichment.arn if enrichment.type == "sfn"])
  enrichment_api_arns    = distinct([for enrichment in values(local.pipe_enrichments) : enrichment.arn if enrichment.type == "api-destination"])

  target_lambda_arns = distinct([for pipe in values(var.pipes) : pipe.target.arn if pipe.target.type == "lambda"])
  target_sqs_arns    = distinct([for pipe in values(var.pipes) : pipe.target.arn if pipe.target.type == "sqs"])

  # Starting a workflow and starting one synchronously are different actions, so a pipe
  # that only ever starts a Standard workflow never gains the express-only permission.
  target_sfn_async_arns = distinct([
    for key, pipe in var.pipes : pipe.target.arn
    if pipe.target.type == "sfn" && local.target_invocation_types[key] == "FIRE_AND_FORGET"
  ])

  target_sfn_sync_arns = distinct([
    for key, pipe in var.pipes : pipe.target.arn
    if pipe.target.type == "sfn" && local.target_invocation_types[key] == "REQUEST_RESPONSE"
  ])

  # An unresolvable bus key is left out of the policy and reported by the precondition on
  # the pipe itself, which produces a readable error instead of an index failure.
  bus_target_keys = { for key, pipe in var.pipes : key => pipe.target.bus if pipe.target.type == "bus" }

  target_bus_arns = distinct([
    for bus_key in values(local.bus_target_keys) : local.bus_arns_by_key[bus_key]
    if contains(keys(local.bus_arns_by_key), bus_key)
  ])

  # The pipe reads an encrypted queue and writes an encrypted destination as itself, so it
  # needs key use directly rather than inheriting it from a service principal.
  pipe_kms_key_arns = distinct(concat(
    local.bus_key_arn != null ? [local.bus_key_arn] : [],
    flatten([for pipe in values(var.pipes) : pipe.additional_kms_key_arns])
  ))
}

# --------------------------------------------------------------------------------------
# Execution logs
# --------------------------------------------------------------------------------------

# A pipe reports what it filtered out, what the enrichment returned, and what the
# destination rejected. Without this the only visible symptom of a bad filter is a queue
# that drains with nothing arriving at the other end.
resource "aws_cloudwatch_log_group" "pipe" {
  for_each = local.logged_pipes

  name              = "/aws/vendedlogs/pipes/${var.name_prefix}-${each.key}"
  retention_in_days = var.pipe_log_retention_days
  kms_key_id        = local.pipe_log_key_arn

  tags = {
    Name = "${var.name_prefix}-${each.key}"
  }
}

# --------------------------------------------------------------------------------------
# Execution role
# --------------------------------------------------------------------------------------

data "aws_iam_policy_document" "pipes_assume" {
  count = local.create_pipes_role ? 1 : 0

  statement {
    sid     = "AllowPipesToAssumeTheExecutionRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }

    # Without both conditions, any account's EventBridge Pipes could assume this role if it
    # ever learned the name. Pairing source account with source ARN is the confused-deputy
    # guard.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:pipes:${var.aws_region}:${data.aws_caller_identity.current.account_id}:pipe/${var.name_prefix}-*"]
    }
  }
}

data "aws_iam_policy_document" "pipes" {
  count = local.create_pipes_role ? 1 : 0

  # Reading a queue means consuming from it: a pipe deletes a message once the destination
  # confirms it, which is why delete sits alongside receive rather than being an extra
  # grant. GetQueueAttributes is how the poller sizes its own concurrency.
  statement {
    sid    = "ConsumeDeclaredSourceQueues"
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]

    resources = local.pipe_source_queue_arns
  }

  dynamic "statement" {
    for_each = length(local.enrichment_lambda_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "InvokeDeclaredEnrichmentFunctions"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = local.enrichment_lambda_arns
    }
  }

  # Enrichment is a synchronous call, so this is the express-only action. A Standard
  # workflow cannot serve an enrichment and will be refused at call time.
  dynamic "statement" {
    for_each = length(local.enrichment_sfn_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "StartDeclaredEnrichmentWorkflows"
      effect    = "Allow"
      actions   = ["states:StartSyncExecution"]
      resources = local.enrichment_sfn_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.enrichment_api_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "InvokeDeclaredEnrichmentApiDestinations"
      effect    = "Allow"
      actions   = ["events:InvokeApiDestination"]
      resources = local.enrichment_api_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.target_lambda_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "InvokeDeclaredDestinationFunctions"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = local.target_lambda_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.target_sqs_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "SendToDeclaredDestinationQueues"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = local.target_sqs_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.target_sfn_async_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "StartDeclaredDestinationWorkflows"
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = local.target_sfn_async_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.target_sfn_sync_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "StartDeclaredDestinationWorkflowsSynchronously"
      effect    = "Allow"
      actions   = ["states:StartSyncExecution"]
      resources = local.target_sfn_sync_arns
    }
  }

  # A pipe delivering onto a bus is publishing a new event, so it needs the same permission
  # any other producer would.
  dynamic "statement" {
    for_each = length(local.target_bus_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "PublishToDeclaredDestinationBuses"
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = local.target_bus_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.logged_pipes) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid     = "WriteExecutionLogs"
      effect  = "Allow"
      actions = ["logs:CreateLogStream", "logs:PutLogEvents"]

      resources = [
        for group in values(aws_cloudwatch_log_group.pipe) : "${group.arn}:*"
      ]
    }
  }

  dynamic "statement" {
    for_each = length(local.pipe_kms_key_arns) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "UseKeysProtectingTheStream"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = local.pipe_kms_key_arns
    }
  }
}

resource "aws_iam_role" "pipes" {
  count = local.create_pipes_role ? 1 : 0

  name                 = "${var.name_prefix}-pipes"
  description          = "Assumed by EventBridge Pipes to read the declared sources, call the declared enrichments, and write the declared destinations."
  assume_role_policy   = data.aws_iam_policy_document.pipes_assume[0].json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-pipes"
  }
}

resource "aws_iam_role_policy" "pipes" {
  count = local.create_pipes_role ? 1 : 0

  name   = "${var.name_prefix}-pipes"
  role   = aws_iam_role.pipes[0].id
  policy = data.aws_iam_policy_document.pipes[0].json
}

# --------------------------------------------------------------------------------------
# Pipes
# --------------------------------------------------------------------------------------

resource "aws_pipes_pipe" "this" {
  for_each = var.pipes

  name          = "${var.name_prefix}-${each.key}"
  description   = coalesce(each.value.description, "Carries messages from a queue to a single destination.")
  role_arn      = local.pipes_role_arn
  desired_state = each.value.desired_state

  source     = each.value.source_queue_arn
  enrichment = try(each.value.enrichment.arn, null)
  target     = each.value.target.type == "bus" ? lookup(local.bus_arns_by_key, each.value.target.bus, "unresolved-event-bus") : each.value.target.arn

  source_parameters {
    sqs_queue_parameters {
      batch_size = each.value.batch_size

      # A batching window trades latency for fewer, larger invocations. Left at zero the
      # pipe delivers as soon as it has anything, which is what a low-volume stream wants.
      maximum_batching_window_in_seconds = each.value.maximum_batching_window_in_seconds
    }

    # Patterns are alternatives: a message that matches any one of them is carried, and a
    # message matching none is deleted from the source queue without reaching the
    # destination. Filtering is therefore a discard, not a diversion.
    dynamic "filter_criteria" {
      for_each = length(each.value.filter_patterns) > 0 ? toset(["enabled"]) : toset([])

      content {
        dynamic "filter" {
          for_each = each.value.filter_patterns

          content {
            pattern = filter.value
          }
        }
      }
    }
  }

  # Whatever the enrichment returns replaces the payload. An enrichment that returns
  # nothing stops the message there, so it doubles as a late filter for decisions that
  # need data the pattern cannot see.
  dynamic "enrichment_parameters" {
    for_each = each.value.enrichment == null ? toset([]) : toset(["enabled"])

    content {
      input_template = each.value.enrichment.input_template

      dynamic "http_parameters" {
        for_each = each.value.enrichment.http_parameters == null ? toset([]) : toset(["enabled"])

        content {
          path_parameter_values   = each.value.enrichment.http_parameters.path_parameter_values
          header_parameters       = each.value.enrichment.http_parameters.header_parameters
          query_string_parameters = each.value.enrichment.http_parameters.query_string_parameters
        }
      }
    }
  }

  target_parameters {
    input_template = each.value.target.input_template

    dynamic "lambda_function_parameters" {
      for_each = each.value.target.type == "lambda" ? toset(["enabled"]) : toset([])

      content {
        invocation_type = local.target_invocation_types[each.key]
      }
    }

    dynamic "step_function_state_machine_parameters" {
      for_each = each.value.target.type == "sfn" ? toset(["enabled"]) : toset([])

      content {
        invocation_type = local.target_invocation_types[each.key]
      }
    }

    dynamic "sqs_queue_parameters" {
      for_each = each.value.target.message_group_id == null ? toset([]) : toset([each.value.target.message_group_id])

      content {
        message_group_id = sqs_queue_parameters.value
      }
    }

    # Delivering onto a bus means publishing, so the event needs the source and detail type
    # its consumers will match on. Neither can be inferred from the message that arrived.
    dynamic "eventbridge_event_bus_parameters" {
      for_each = each.value.target.type == "bus" ? toset(["enabled"]) : toset([])

      content {
        detail_type = each.value.target.detail_type
        source      = each.value.target.source
      }
    }
  }

  dynamic "log_configuration" {
    for_each = each.value.log_level == "OFF" ? toset([]) : toset(["enabled"])

    content {
      level = each.value.log_level

      # Execution data is the message itself. It is the fastest way to see why a filter is
      # not matching and the fastest way to spill payload contents into a log group, so it
      # stays off unless asked for.
      include_execution_data = each.value.include_execution_data ? ["ALL"] : null

      cloudwatch_logs_log_destination {
        log_group_arn = aws_cloudwatch_log_group.pipe[each.key].arn
      }
    }
  }

  tags = {
    Name = "${var.name_prefix}-${each.key}"
  }

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-${each.key}") <= 64
      error_message = "The prefixed pipe name for ${each.key} exceeds the 64-character limit. Shorten name_prefix or the pipe key."
    }

    precondition {
      condition = each.value.target.type != "bus" ? true : (
        each.value.target.bus == null ? false : contains(keys(var.event_buses), each.value.target.bus)
      )
      error_message = "Pipe ${each.key} delivers to bus ${each.value.target.bus != null ? each.value.target.bus : "(unset)"}, which is not declared in event_buses. Declare the bus or point the pipe at an existing key."
    }
  }
}
