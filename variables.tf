variable "aws_region" {
  description = "AWS region hosting the event buses, archives, and schema registry."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region identifier, for example us-east-1."
  }
}

variable "name_prefix" {
  description = "Short lowercase prefix applied to every created resource name."
  type        = string
  default     = "events-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "default_tags" {
  description = "Tags applied to every resource that supports tagging."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Component = "event-backbone"
  }
}

variable "event_buses" {
  description = "Custom event buses to create, keyed by an unprefixed bus name. Each entry controls its own archive retention, schema discovery, and undeliverable-event queue."
  type = map(object({
    description              = optional(string)
    schema_discovery_enabled = optional(bool, false)
    dead_letter_queue_arn    = optional(string)
    archive = optional(object({
      enabled        = optional(bool, true)
      description    = optional(string)
      retention_days = optional(number, 90)
      event_pattern  = optional(string)
    }), {})
  }))

  default = {
    "platform-core" = {
      description              = "Domain events published by first-party services and shared platform components."
      schema_discovery_enabled = true

      archive = {
        retention_days = 90
      }
    }

    "platform-integration" = {
      description = "Events exchanged with partner, vendor, and third-party systems."

      archive = {
        retention_days = 365
      }
    }
  }

  validation {
    condition     = length(var.event_buses) > 0
    error_message = "At least one custom event bus must be declared."
  }

  validation {
    condition = alltrue([
      for name in keys(var.event_buses) : can(regex("^[A-Za-z0-9._-]{1,180}$", name))
    ])
    error_message = "Event bus keys may contain only letters, digits, dots, underscores, and hyphens, and must be at most 180 characters so the prefixed name stays within the 256-character limit."
  }

  validation {
    condition = alltrue([
      for name in keys(var.event_buses) : lower(name) != "default"
    ])
    error_message = "A bus may not be named default: that name is reserved for the AWS-managed account bus, which this configuration deliberately leaves alone."
  }

  validation {
    condition = alltrue([
      for cfg in values(var.event_buses) :
      cfg.archive.retention_days >= 0 && cfg.archive.retention_days <= 3653
    ])
    error_message = "Archive retention_days must be between 0 (retain indefinitely) and 3653."
  }

  validation {
    condition = alltrue([
      for cfg in values(var.event_buses) :
      cfg.archive.event_pattern == null ? true : can(jsondecode(cfg.archive.event_pattern))
    ])
    error_message = "Archive event_pattern must be a JSON document when set."
  }

  validation {
    condition = alltrue([
      for cfg in values(var.event_buses) :
      cfg.dead_letter_queue_arn == null ? true : can(regex("^arn:aws[a-zA-Z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", cfg.dead_letter_queue_arn))
    ])
    error_message = "dead_letter_queue_arn must be an SQS queue ARN when set."
  }
}

variable "create_kms_key" {
  description = "Create a customer managed key for bus and archive encryption. Ignored when kms_key_arn supplies an existing key."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "ARN of an existing customer managed key to encrypt bus and archive contents. Leave null to let this configuration manage the key."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null ? true : can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN when set."
  }
}

variable "kms_deletion_window_days" {
  description = "Waiting period before a scheduled key deletion completes."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "create_schema_registry" {
  description = "Create a registry to hold hand-authored event contracts alongside the schemas that discovery infers."
  type        = bool
  default     = true
}

variable "schema_registry_description" {
  description = "Description applied to the contract schema registry."
  type        = string
  default     = "Event contracts published by producing teams and consumed as generated bindings."
}

variable "publish_contract_schemas" {
  description = "Publish every OpenAPI 3 document under schemas/ into the contract registry."
  type        = bool
  default     = true
}

variable "event_rules" {
  description = "Pattern-matched rules routing events off a declared bus to typed targets. Keyed by an unprefixed rule name. Ships empty because every target ARN names a resource owned outside this configuration; see the README for a worked example."
  type = map(object({
    bus           = string
    event_pattern = string
    description   = optional(string)
    state         = optional(string, "ENABLED")

    targets = map(object({
      type                  = string
      arn                   = string
      input                 = optional(string)
      input_path            = optional(string)
      message_group_id      = optional(string)
      dead_letter_queue_arn = optional(string)
      manage_queue_policy   = optional(bool, false)
      role_arn              = optional(string)

      maximum_event_age_in_seconds = optional(number)
      maximum_retry_attempts       = optional(number)

      input_transformer = optional(object({
        input_paths    = optional(map(string), {})
        input_template = string
      }))
    }))
  }))

  default = {}

  validation {
    condition = alltrue([
      for name in keys(var.event_rules) : can(regex("^[A-Za-z0-9._-]{1,64}$", name))
    ])
    error_message = "Rule keys may contain only letters, digits, dots, underscores, and hyphens, and must be at most 64 characters."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : can(jsondecode(rule.event_pattern))
    ])
    error_message = "Every rule must declare event_pattern as a JSON document. Scheduled invocation is not accepted here: EventBridge only supports schedule expressions on the AWS-managed default bus."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : contains(["ENABLED", "DISABLED"], rule.state)
    ])
    error_message = "Rule state must be ENABLED or DISABLED."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : length(rule.targets) > 0
    ])
    error_message = "Every rule must declare at least one target. A rule with no targets matches events and discards them."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for name in keys(rule.targets) : can(regex("^[A-Za-z0-9._-]{1,64}$", name))
      ])
    ])
    error_message = "Target keys may contain only letters, digits, dots, underscores, and hyphens, and must be at most 64 characters."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : contains(["lambda", "sqs", "sfn"], target.type)
      ])
    ])
    error_message = "Target type must be one of lambda, sqs, or sfn."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.type != "lambda" ? true : can(regex("^arn:aws[a-zA-Z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+(:[A-Za-z0-9_$-]+)?$", target.arn))
        )
      ])
    ])
    error_message = "A lambda target must carry a Lambda function ARN, optionally qualified with a version or alias."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.type != "sqs" ? true : can(regex("^arn:aws[a-zA-Z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+(\\.fifo)?$", target.arn))
        )
      ])
    ])
    error_message = "An sqs target must carry an SQS queue ARN."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.type != "sfn" ? true : can(regex("^arn:aws[a-zA-Z-]*:states:[a-z0-9-]+:[0-9]{12}:stateMachine:[A-Za-z0-9_-]+$", target.arn))
        )
      ])
    ])
    error_message = "An sfn target must carry a Step Functions state machine ARN."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.message_group_id == null ? true : (target.type == "sqs" && endswith(target.arn, ".fifo"))
        )
      ])
    ])
    error_message = "message_group_id applies only to an sqs target whose queue name ends in .fifo."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          endswith(target.arn, ".fifo") ? target.message_group_id != null : true
        )
      ])
    ])
    error_message = "A FIFO queue target must declare message_group_id: a FIFO queue rejects a message that arrives without one."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) :
        length([for setting in [target.input, target.input_path, target.input_transformer] : setting if setting != null]) <= 1
      ])
    ])
    error_message = "At most one of input, input_path, or input_transformer may be set on a target."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.input == null ? true : can(jsondecode(target.input))
        )
      ])
    ])
    error_message = "A static target input must be a JSON document."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.input_transformer == null ? true : alltrue([
            for placeholder in regexall("<([A-Za-z0-9._:-]+)>", target.input_transformer.input_template) :
            contains(keys(target.input_transformer.input_paths), placeholder[0]) || startswith(placeholder[0], "aws.events.")
          ])
        )
      ])
    ])
    error_message = "Every placeholder in an input_template must be declared in input_paths, or be one of the reserved aws.events.* values EventBridge supplies."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.role_arn == null ? true : target.type == "sfn"
        )
      ])
    ])
    error_message = "A target role applies only to an sfn target. EventBridge authorizes a Lambda or SQS target through a resource policy on the target itself, so a role there would be accepted and never used."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.manage_queue_policy ? target.type == "sqs" : true
        )
      ])
    ])
    error_message = "manage_queue_policy applies only to an sqs target."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.role_arn == null ? true : can(regex("^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:role/", target.role_arn))
        )
      ])
    ])
    error_message = "A target role_arn must be an IAM role ARN when set."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.dead_letter_queue_arn == null ? true : can(regex("^arn:aws[a-zA-Z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+(\\.fifo)?$", target.dead_letter_queue_arn))
        )
      ])
    ])
    error_message = "A target dead_letter_queue_arn must be an SQS queue ARN when set."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.maximum_retry_attempts == null ? true : (target.maximum_retry_attempts >= 0 && target.maximum_retry_attempts <= 185)
        )
      ])
    ])
    error_message = "maximum_retry_attempts must be between 0 and 185."
  }

  validation {
    condition = alltrue([
      for rule in values(var.event_rules) : alltrue([
        for target in values(rule.targets) : (
          target.maximum_event_age_in_seconds == null ? true : (target.maximum_event_age_in_seconds >= 60 && target.maximum_event_age_in_seconds <= 86400)
        )
      ])
    ])
    error_message = "maximum_event_age_in_seconds must be between 60 and 86400."
  }
}

variable "default_target_retry_policy" {
  description = "Retry window applied to any target that does not override it. The service default of 24 hours is deliberately shortened so a broken consumer reaches its dead-letter queue in an hour rather than a day."
  type = object({
    maximum_event_age_in_seconds = optional(number, 3600)
    maximum_retry_attempts       = optional(number, 10)
  })
  default = {}

  validation {
    condition     = var.default_target_retry_policy.maximum_event_age_in_seconds >= 60 && var.default_target_retry_policy.maximum_event_age_in_seconds <= 86400
    error_message = "default_target_retry_policy.maximum_event_age_in_seconds must be between 60 and 86400."
  }

  validation {
    condition     = var.default_target_retry_policy.maximum_retry_attempts >= 0 && var.default_target_retry_policy.maximum_retry_attempts <= 185
    error_message = "default_target_retry_policy.maximum_retry_attempts must be between 0 and 185."
  }
}

variable "create_rule_dead_letter_queues" {
  description = "Create one undeliverable-event queue per rule. A target that names its own dead_letter_queue_arn uses that instead."
  type        = bool
  default     = true
}

variable "dead_letter_queue_retention_seconds" {
  description = "How long an undeliverable event stays in a managed dead-letter queue before SQS discards it."
  type        = number
  default     = 1209600

  validation {
    condition     = var.dead_letter_queue_retention_seconds >= 60 && var.dead_letter_queue_retention_seconds <= 1209600
    error_message = "dead_letter_queue_retention_seconds must be between 60 and 1209600 (14 days, the SQS maximum)."
  }
}

variable "manage_lambda_target_permissions" {
  description = "Attach the invoke permission each Lambda target needs. Turn off where the function's resource policy is owned by the team that owns the function."
  type        = bool
  default     = true
}

variable "step_functions_invocation_role_arn" {
  description = "ARN of an existing role EventBridge should assume to start state machine targets. Leave null to let this configuration create one scoped to exactly the declared state machines."
  type        = string
  default     = null

  validation {
    condition     = var.step_functions_invocation_role_arn == null ? true : can(regex("^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:role/", var.step_functions_invocation_role_arn))
    error_message = "step_functions_invocation_role_arn must be an IAM role ARN when set."
  }
}
