# Custom event buses, their durable archives, the key that protects both, and the schema
# surface that tells consumers what they are allowed to expect.
#
# Three deliberate choices are worth calling out:
#
#   1. The AWS-managed default bus is never touched. It carries service events for the
#      whole account and cannot be given a narrow resource policy, so it is the wrong
#      place to put application traffic that needs its own retention and access rules.
#
#   2. An archive is created alongside every bus unless explicitly disabled. Replay is the
#      only way to recover from a consumer that was broken while events were flowing, and
#      an archive that was not configured before the incident cannot be added afterward.
#
#   3. Discovery and published contracts run together rather than as alternatives.
#      Contracts state what producers promise; discovery reports what is actually on the
#      bus. The gap between the two is the interesting signal.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  # An explicitly supplied key always wins, so a caller with a central key never ends up
  # with a second unused one.
  create_key  = var.create_kms_key && var.kms_key_arn == null
  bus_key_arn = var.kms_key_arn != null ? var.kms_key_arn : one(aws_kms_key.events[*].arn)

  archived_buses = {
    for name, cfg in var.event_buses : name => cfg
    if cfg.archive.enabled
  }

  discovered_buses = {
    for name, cfg in var.event_buses : name => cfg
    if cfg.schema_discovery_enabled
  }

  # Publishing a contract without a registry to hold it is a silent no-op, so the two
  # switches are combined once here and the contradiction is surfaced as a precondition.
  publish_schemas = var.publish_contract_schemas && var.create_schema_registry

  contract_schema_files = local.publish_schemas ? fileset("${path.module}/schemas", "*.json") : toset([])

  # A contract is added by adding a file. The registered schema name is derived from the
  # event markers inside the document rather than from its filename, so renaming a file
  # cannot quietly detach a contract from the events it describes.
  contract_schemas = {
    for file_name in local.contract_schema_files : trimsuffix(file_name, ".json") => {
      body   = file("${path.module}/schemas/${file_name}")
      parsed = jsondecode(file("${path.module}/schemas/${file_name}"))
    }
  }
}

# --------------------------------------------------------------------------------------
# Encryption
# --------------------------------------------------------------------------------------

data "aws_iam_policy_document" "events_key" {
  count = local.create_key ? 1 : 0

  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowEventBridgeToUseTheKey"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Archive and replay hold events beyond the lifetime of a single API call, so the
  # service needs a grant rather than a one-shot decrypt. The grant is constrained to
  # AWS resources and to this account.
  statement {
    sid    = "AllowEventBridgeToCreateGrantsForArchiveAndReplay"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Pipe execution logs are encrypted with this same key unless a separate one is supplied,
  # so CloudWatch Logs needs use of it. The encryption context pins the grant to log groups
  # in this account and region, and the statement is omitted entirely when no pipe logs.
  dynamic "statement" {
    for_each = local.grant_logs_key_use ? toset(["enabled"]) : toset([])

    content {
      sid    = "AllowCloudWatchLogsToUseTheKey"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["logs.${var.aws_region}.amazonaws.com"]
      }

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]

      resources = ["*"]

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
      }
    }
  }

  # A schedule's stored target payload is encrypted with this same key unless a separate
  # one is supplied. EventBridge Scheduler reads that payload as the role the schedule
  # assumes rather than as a service principal, so the grant names that role. Admitting it
  # by its predicted ARN keeps this statement dependent on inputs alone, so the key never
  # waits on the role it is admitting.
  dynamic "statement" {
    for_each = local.grant_scheduler_key_use ? toset(["enabled"]) : toset([])

    content {
      sid    = "AllowScheduleExecutionRoleToUseTheKey"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
      }

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
      ]

      resources = ["*"]

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = [local.scheduler_principal_arn]
      }
    }
  }
}

resource "aws_kms_key" "events" {
  count = local.create_key ? 1 : 0

  description             = "Encrypts custom event bus and archive contents for ${var.name_prefix}."
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days
  policy                  = data.aws_iam_policy_document.events_key[0].json

  tags = {
    Name = "${var.name_prefix}-events"
  }
}

resource "aws_kms_alias" "events" {
  count = local.create_key ? 1 : 0

  name          = "alias/${var.name_prefix}-events"
  target_key_id = aws_kms_key.events[0].key_id
}

# --------------------------------------------------------------------------------------
# Buses
# --------------------------------------------------------------------------------------

resource "aws_cloudwatch_event_bus" "this" {
  for_each = var.event_buses

  name               = "${var.name_prefix}-${each.key}"
  description        = each.value.description
  kms_key_identifier = local.bus_key_arn

  # An event that cannot be delivered to the bus at all is a different failure from a
  # target that rejects it, and it is invisible without somewhere to land.
  dynamic "dead_letter_config" {
    for_each = each.value.dead_letter_queue_arn == null ? toset([]) : toset([each.value.dead_letter_queue_arn])

    content {
      arn = dead_letter_config.value
    }
  }

  tags = {
    Name = "${var.name_prefix}-${each.key}"
  }

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-${each.key}") <= 256
      error_message = "The prefixed event bus name exceeds the 256-character limit."
    }
  }
}

# --------------------------------------------------------------------------------------
# Archives
# --------------------------------------------------------------------------------------

resource "aws_cloudwatch_event_archive" "this" {
  for_each = local.archived_buses

  name             = "${var.name_prefix}-${each.key}-archive"
  description      = coalesce(each.value.archive.description, "Replay buffer for the ${each.key} event bus.")
  event_source_arn = aws_cloudwatch_event_bus.this[each.key].arn
  retention_days   = each.value.archive.retention_days

  # Omitting the pattern archives everything the bus accepts. Narrowing it is a cost
  # decision, not a correctness one, so it is left to the caller.
  event_pattern = each.value.archive.event_pattern

  # An archive over an encrypted bus must use the same key, otherwise the archive is
  # rejected at create time rather than silently storing plaintext.
  kms_key_identifier = local.bus_key_arn

  lifecycle {
    precondition {
      condition     = each.value.archive.event_pattern == null || can(jsondecode(each.value.archive.event_pattern))
      error_message = "The archive event_pattern for bus ${each.key} is not valid JSON."
    }
  }
}

# --------------------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------------------

resource "terraform_data" "schema_publication_guard" {
  count = var.publish_contract_schemas && !var.create_schema_registry ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.create_schema_registry
      error_message = "publish_contract_schemas is enabled but create_schema_registry is false, so the contracts under schemas/ would have nowhere to be published. Enable the registry or stop publishing contracts."
    }
  }
}

resource "aws_schemas_registry" "contracts" {
  count = var.create_schema_registry ? 1 : 0

  name        = "${var.name_prefix}-contracts"
  description = var.schema_registry_description

  tags = {
    Name = "${var.name_prefix}-contracts"
  }
}

resource "aws_schemas_schema" "contract" {
  for_each = local.contract_schemas

  name          = format("%s@%s", each.value.parsed.components.schemas.AWSEvent["x-amazon-events-source"], replace(each.value.parsed.components.schemas.AWSEvent["x-amazon-events-detail-type"], " ", ""))
  registry_name = one(aws_schemas_registry.contracts[*].name)
  type          = "OpenApi3"
  description   = try(each.value.parsed.info.title, each.key)
  content       = each.value.body

  tags = {
    Name = each.key
  }

  lifecycle {
    precondition {
      condition     = can(each.value.parsed.components.schemas.AWSEvent["x-amazon-events-source"]) && can(each.value.parsed.components.schemas.AWSEvent["x-amazon-events-detail-type"])
      error_message = "Contract ${each.key}.json must declare both x-amazon-events-source and x-amazon-events-detail-type on its AWSEvent component so the registered schema name can be derived from the contract itself."
    }

    precondition {
      condition     = try(each.value.parsed.info.version, null) != null
      error_message = "Contract ${each.key}.json must declare info.version so consumers can pin a generated binding."
    }
  }
}

# --------------------------------------------------------------------------------------
# Discovery
# --------------------------------------------------------------------------------------

# Discovery answers the question contracts cannot: what is actually being published that
# nobody declared. It writes into the AWS-managed discovered-schemas registry, kept
# separate from the curated contract registry above so inference is never mistaken for
# an agreement.
resource "aws_schemas_discoverer" "this" {
  for_each = local.discovered_buses

  source_arn  = aws_cloudwatch_event_bus.this[each.key].arn
  description = "Infers schemas from traffic on the ${each.key} event bus."

  tags = {
    Name = "${var.name_prefix}-${each.key}-discoverer"
  }
}
