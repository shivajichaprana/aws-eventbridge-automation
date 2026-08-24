# Routing across an account boundary, in both directions.
#
# Cross-account delivery is two independent halves, owned by two different teams, and
# almost every failure comes from forgetting that only one of them was done:
#
#   1. INBOUND is a resource policy on the receiving bus. A bus accepts events only from
#      its own account until it says otherwise, so the account that OWNS the bus decides
#      who may publish to it. That half lives in cross_account_access below.
#
#   2. OUTBOUND is a rule with a remote bus as its target, plus a role EventBridge assumes
#      to publish there. That half lives in cross_account_forwarding, and it will fail with
#      an access denial until the receiving account has done the first half.
#
# Two things worth knowing before wiring a route:
#
#   * The receiving bus sees the event with the SENDING account's id in the account field,
#      while source and detail-type survive unchanged. So a consumer that needs to know
#      where an event came from should read the account field rather than assuming source
#      encodes it.
#
#   * Design for a single hop. Forwarding an event that was itself forwarded makes the
#      path hard to reason about, and a cycle between two buses is self-sustaining and
#      bills on every pass. Preconditions here reject the degenerate case of a bus
#      forwarding to itself; a longer cycle is a review question, not a machine-checkable
#      one.
#
# The grant is deliberately narrowable. Naming an account and stopping there lets that
# account put anything at all onto the bus, including something shaped to match a rule it
# was never meant to trigger. allowed_sources and allowed_detail_types turn the grant into
# what the producer actually publishes.

locals {
  # An entry naming an undeclared bus is filtered out here and reported by the guard below,
  # so an unknown key produces a readable error rather than an index failure.
  cross_account_buses = {
    for key, cfg in var.cross_account_access : key => cfg
    if contains(keys(var.event_buses), key)
  }

  undeclared_cross_account_buses = sort([
    for key in keys(var.cross_account_access) : key if !contains(keys(var.event_buses), key)
  ])

  # Account ids are expanded to root ARNs, which is what a resource policy names when it
  # trusts a whole account and lets that account delegate onward through its own IAM.
  cross_account_named_principals = {
    for key, cfg in local.cross_account_buses : key => concat(
      [for account_id in cfg.account_ids : "arn:${data.aws_partition.current.partition}:iam::${account_id}:root"],
      cfg.principal_arns
    )
  }

  # Forwarding rules are namespaced so they can never collide with the routing rules
  # declared alongside them, and the guard below proves it rather than assuming it.
  forwarding_rule_names = {
    for key in keys(var.cross_account_forwarding) : key => "${var.name_prefix}-forward-${key}"
  }

  routing_rule_names = [for key in keys(var.event_rules) : "${var.name_prefix}-${key}"]

  colliding_rule_names = sort(setintersection(
    toset(values(local.forwarding_rule_names)),
    toset(local.routing_rule_names)
  ))

  # One flat map of every forwarding rule and destination pair. The target identifier is
  # built from the destination's account, region, and bus name so the console shows where
  # an event went rather than an opaque index.
  forwarding_targets = merge([
    for key, fwd in var.cross_account_forwarding : {
      for arn in fwd.destination_bus_arns :
      "${key}/${element(split(":", arn), 4)}-${element(split(":", arn), 3)}-${element(split("/", arn), 1)}" => {
        forwarding_key = key
        target_id      = "${element(split(":", arn), 4)}-${element(split(":", arn), 3)}-${element(split("/", arn), 1)}"
        arn            = arn

        dead_letter_queue_arn        = fwd.dead_letter_queue_arn
        maximum_event_age_in_seconds = fwd.maximum_event_age_in_seconds
        maximum_retry_attempts       = fwd.maximum_retry_attempts
      }
    }
  ]...)

  # Predicted from inputs alone rather than read back from the created buses, so the
  # forward-to-self guard reports at plan time instead of waiting for apply.
  local_bus_arns = [
    for key in keys(var.event_buses) :
    "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:event-bus/${var.name_prefix}-${key}"
  ]

  forwarding_destination_arns = distinct(flatten([
    for fwd in values(var.cross_account_forwarding) : fwd.destination_bus_arns
  ]))

  create_forwarding_role = length(var.cross_account_forwarding) > 0 && var.cross_account_forwarding_role_arn == null
  forwarding_role_arn    = var.cross_account_forwarding_role_arn != null ? var.cross_account_forwarding_role_arn : one(aws_iam_role.cross_account_forwarding[*].arn)

  forwarding_without_dead_letter = sort([
    for key, fwd in var.cross_account_forwarding : key if fwd.dead_letter_queue_arn == null
  ])
}

resource "terraform_data" "cross_account_guard" {
  count = length(var.cross_account_access) + length(var.cross_account_forwarding) > 0 ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.undeclared_cross_account_buses) == 0
      error_message = "cross_account_access grants access to buses that are not declared in event_buses: ${join(", ", local.undeclared_cross_account_buses)}. A grant on a bus that does not exist would be silently dropped."
    }

    precondition {
      condition     = length(local.colliding_rule_names) == 0
      error_message = "A forwarding rule and a routing rule would be created with the same name: ${join(", ", local.colliding_rule_names)}. Rename the entry in event_rules or in cross_account_forwarding."
    }
  }
}

# --------------------------------------------------------------------------------------
# Inbound: who may publish onto a local bus
# --------------------------------------------------------------------------------------

data "aws_iam_policy_document" "cross_account_bus" {
  for_each = local.cross_account_buses

  # Named accounts and named principals share one statement: both are identified by ARN,
  # and separating them would only duplicate the conditions attached to each.
  dynamic "statement" {
    for_each = length(local.cross_account_named_principals[each.key]) > 0 ? toset(["enabled"]) : toset([])

    content {
      sid       = "AllowNamedPrincipalsToPutEvents"
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = [aws_cloudwatch_event_bus.this[each.key].arn]

      principals {
        type        = "AWS"
        identifiers = local.cross_account_named_principals[each.key]
      }

      dynamic "condition" {
        for_each = length(each.value.allowed_sources) > 0 ? toset(["enabled"]) : toset([])

        content {
          test     = "StringEquals"
          variable = "events:source"
          values   = each.value.allowed_sources
        }
      }

      dynamic "condition" {
        for_each = length(each.value.allowed_detail_types) > 0 ? toset(["enabled"]) : toset([])

        content {
          test     = "StringEquals"
          variable = "events:detail-type"
          values   = each.value.allowed_detail_types
        }
      }
    }
  }

  # An organization grant is its own statement because it is expressed differently: the
  # principal is open and the organization condition is what closes it. Merging it with the
  # named-principal statement above would widen that statement to everyone.
  dynamic "statement" {
    for_each = each.value.organization_id == null ? toset([]) : toset([each.value.organization_id])

    content {
      sid       = "AllowOrganizationToPutEvents"
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = [aws_cloudwatch_event_bus.this[each.key].arn]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalOrgID"
        values   = [statement.value]
      }

      dynamic "condition" {
        for_each = length(each.value.allowed_sources) > 0 ? toset(["enabled"]) : toset([])

        content {
          test     = "StringEquals"
          variable = "events:source"
          values   = each.value.allowed_sources
        }
      }

      dynamic "condition" {
        for_each = length(each.value.allowed_detail_types) > 0 ? toset(["enabled"]) : toset([])

        content {
          test     = "StringEquals"
          variable = "events:detail-type"
          values   = each.value.allowed_detail_types
        }
      }
    }
  }

  # Letting another account create rules on this bus means letting it decide where these
  # events go next, which is a much larger grant than publishing. The creatorAccount
  # condition confines each account to the rules it created, so one grantee cannot read,
  # edit, or delete another's routing.
  dynamic "statement" {
    for_each = each.value.allow_rule_management ? toset(["enabled"]) : toset([])

    content {
      sid       = "AllowNamedPrincipalsToManageTheirOwnRules"
      effect    = "Allow"
      resources = [aws_cloudwatch_event_bus.this[each.key].arn]

      actions = [
        "events:PutRule",
        "events:DeleteRule",
        "events:DescribeRule",
        "events:DisableRule",
        "events:EnableRule",
        "events:PutTargets",
        "events:RemoveTargets",
        "events:ListTargetsByRule",
        "events:ListTagsForResource",
        "events:TagResource",
        "events:UntagResource",
      ]

      principals {
        type        = "AWS"
        identifiers = local.cross_account_named_principals[each.key]
      }

      condition {
        test     = "StringEqualsIfExists"
        variable = "events:creatorAccount"
        values   = ["$${aws:PrincipalAccount}"]
      }
    }
  }
}

resource "aws_cloudwatch_event_bus_policy" "cross_account" {
  for_each = local.cross_account_buses

  event_bus_name = aws_cloudwatch_event_bus.this[each.key].name
  policy         = data.aws_iam_policy_document.cross_account_bus[each.key].json
}

# --------------------------------------------------------------------------------------
# Outbound: copying local events onto a remote bus
# --------------------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "cross_account_forwarding" {
  for_each = var.cross_account_forwarding

  name           = local.forwarding_rule_names[each.key]
  description    = coalesce(each.value.description, "Copies matching events off the ${each.value.bus} bus onto a bus in another account.")
  event_bus_name = lookup(local.bus_names_by_key, each.value.bus, "unresolved-event-bus")
  event_pattern  = each.value.event_pattern
  state          = each.value.state

  tags = {
    Name = local.forwarding_rule_names[each.key]
  }

  lifecycle {
    precondition {
      condition     = contains(keys(var.event_buses), each.value.bus)
      error_message = "Forwarding rule ${each.key} reads from bus ${each.value.bus}, which is not declared in event_buses."
    }

    precondition {
      condition     = length(local.forwarding_rule_names[each.key]) <= 64
      error_message = "The prefixed forwarding rule name for ${each.key} exceeds the 64-character limit."
    }
  }
}

resource "aws_cloudwatch_event_target" "cross_account_forwarding" {
  for_each = local.forwarding_targets

  rule           = aws_cloudwatch_event_rule.cross_account_forwarding[each.value.forwarding_key].name
  event_bus_name = aws_cloudwatch_event_rule.cross_account_forwarding[each.value.forwarding_key].event_bus_name
  target_id      = each.value.target_id
  arn            = each.value.arn

  # Publishing to another account's bus is one of the target types EventBridge performs by
  # assuming a role, so this is never null.
  role_arn = local.forwarding_role_arn

  retry_policy {
    maximum_event_age_in_seconds = each.value.maximum_event_age_in_seconds != null ? each.value.maximum_event_age_in_seconds : var.default_target_retry_policy.maximum_event_age_in_seconds
    maximum_retry_attempts       = each.value.maximum_retry_attempts != null ? each.value.maximum_retry_attempts : var.default_target_retry_policy.maximum_retry_attempts
  }

  # A cross-account delivery fails for reasons entirely outside this account's control, so
  # a queue here is the difference between a known gap and a silent one.
  dynamic "dead_letter_config" {
    for_each = each.value.dead_letter_queue_arn == null ? toset([]) : toset([each.value.dead_letter_queue_arn])

    content {
      arn = dead_letter_config.value
    }
  }

  lifecycle {
    precondition {
      condition     = !contains(local.local_bus_arns, each.value.arn)
      error_message = "Forwarding rule ${each.value.forwarding_key} targets ${each.value.arn}, which is a bus this configuration creates. A bus forwarding to itself or to a sibling in the same account is a loop that bills on every pass."
    }

    precondition {
      condition     = length(each.value.target_id) <= 64
      error_message = "The generated target identifier ${each.value.target_id} exceeds the 64-character limit. Shorten the destination bus name."
    }
  }
}

data "aws_iam_policy_document" "cross_account_forwarding_assume" {
  count = local.create_forwarding_role ? 1 : 0

  statement {
    sid     = "AllowEventBridgeToAssumeTheForwardingRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    # A rule on a custom bus carries the bus name in its ARN, between the rule segment and
    # the rule name, so both shapes are listed: the second matches every rule this
    # configuration creates, and the first covers the default-bus form.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"

      values = [
        "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${var.name_prefix}-forward-*",
        "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/*/${var.name_prefix}-forward-*",
      ]
    }
  }
}

data "aws_iam_policy_document" "cross_account_forwarding" {
  count = local.create_forwarding_role ? 1 : 0

  statement {
    sid       = "PublishToDeclaredRemoteBuses"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = local.forwarding_destination_arns
  }
}

resource "aws_iam_role" "cross_account_forwarding" {
  count = local.create_forwarding_role ? 1 : 0

  name                 = "${var.name_prefix}-cross-account-forwarding"
  description          = "Assumed by EventBridge to publish forwarded events onto the declared buses in other accounts."
  assume_role_policy   = data.aws_iam_policy_document.cross_account_forwarding_assume[0].json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-cross-account-forwarding"
  }
}

resource "aws_iam_role_policy" "cross_account_forwarding" {
  count = local.create_forwarding_role ? 1 : 0

  name   = "publish-to-remote-buses"
  role   = aws_iam_role.cross_account_forwarding[0].id
  policy = data.aws_iam_policy_document.cross_account_forwarding[0].json
}
