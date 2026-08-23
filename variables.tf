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

variable "pipes" {
  description = "Point-to-point connectors, keyed by an unprefixed pipe name. Each pipe polls one SQS queue, optionally filters and enriches what it reads, and delivers to exactly one destination. Ships empty because every source and destination ARN names a resource owned outside this configuration; see the README for a worked example."
  type = map(object({
    source_queue_arn = string
    description      = optional(string)
    desired_state    = optional(string, "RUNNING")

    batch_size                         = optional(number, 10)
    maximum_batching_window_in_seconds = optional(number, 0)

    # Matched against the SQS envelope a pipe reads, NOT against a bus event. A pattern
    # shaped like a rule's event_pattern matches nothing here.
    filter_patterns = optional(list(string), [])

    # Keys protecting the source queue or the destination, where those differ from the
    # bus key. The pipe reads and writes with its own role, so it needs key use directly.
    additional_kms_key_arns = optional(list(string), [])

    enrichment = optional(object({
      type           = string
      arn            = string
      input_template = optional(string)

      http_parameters = optional(object({
        path_parameter_values   = optional(list(string), [])
        header_parameters       = optional(map(string), {})
        query_string_parameters = optional(map(string), {})
      }))
    }))

    target = object({
      type             = string
      arn              = optional(string)
      bus              = optional(string)
      input_template   = optional(string)
      invocation_type  = optional(string)
      message_group_id = optional(string)
      detail_type      = optional(string)
      source           = optional(string)
    })

    log_level              = optional(string, "ERROR")
    include_execution_data = optional(bool, false)
  }))

  default = {}

  validation {
    condition = alltrue([
      for name in keys(var.pipes) : can(regex("^[A-Za-z0-9._-]{1,64}$", name))
    ])
    error_message = "Pipe keys may contain only letters, digits, dots, underscores, and hyphens, and must be at most 64 characters."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) :
      can(regex("^arn:aws[a-zA-Z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+(\\.fifo)?$", pipe.source_queue_arn))
    ])
    error_message = "Every pipe must name an SQS queue ARN as its source."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : contains(["RUNNING", "STOPPED"], pipe.desired_state)
    ])
    error_message = "Pipe desired_state must be RUNNING or STOPPED. Ship a pipe over an existing backlog as STOPPED, confirm the destination, then start it."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : pipe.batch_size >= 1 && pipe.batch_size <= 10
    ])
    error_message = "batch_size must be between 1 and 10 for an SQS source."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) :
      pipe.maximum_batching_window_in_seconds >= 0 && pipe.maximum_batching_window_in_seconds <= 300
    ])
    error_message = "maximum_batching_window_in_seconds must be between 0 and 300."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : length(pipe.filter_patterns) <= 5
    ])
    error_message = "A pipe may declare at most 5 filter patterns. Patterns are evaluated as alternatives, so widen an existing one rather than adding a sixth."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : alltrue([
        for pattern in pipe.filter_patterns : can(jsondecode(pattern))
      ])
    ])
    error_message = "Every filter pattern must be a JSON document."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : alltrue([
        # Guarded: a pattern that is not JSON is reported by the validation above, and
        # decoding it here would abort the plan rather than fail this check cleanly.
        for pattern in pipe.filter_patterns : (
          can(jsondecode(pattern))
          ? length(setintersection(
            toset(keys(jsondecode(pattern))),
            toset(["source", "detail-type", "detail"])
          )) == 0
          : true
        )
      ])
    ])
    error_message = "A pipe filter is matched against the SQS envelope a pipe reads, whose fields are body, messageAttributes, attributes, eventSource, and eventSourceARN. Top-level source, detail-type, or detail belong to a bus event pattern and would match nothing. Filter on the message body instead, for example {\"body\":{\"status\":[\"SETTLED\"]}}."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : alltrue([
        for key in pipe.additional_kms_key_arns : can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", key))
      ])
    ])
    error_message = "Every entry in additional_kms_key_arns must be a KMS key ARN."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.enrichment == null ? true : contains(["lambda", "sfn", "api-destination"], pipe.enrichment.type)
      )
    ])
    error_message = "Enrichment type must be one of lambda, sfn, or api-destination."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.enrichment == null || try(pipe.enrichment.type, "") != "lambda" ? true :
        can(regex("^arn:aws[a-zA-Z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+(:[A-Za-z0-9_$-]+)?$", pipe.enrichment.arn))
      )
    ])
    error_message = "A lambda enrichment must carry a Lambda function ARN, optionally qualified with a version or alias."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.enrichment == null || try(pipe.enrichment.type, "") != "sfn" ? true :
        can(regex("^arn:aws[a-zA-Z-]*:states:[a-z0-9-]+:[0-9]{12}:stateMachine:[A-Za-z0-9_-]+$", pipe.enrichment.arn))
      )
    ])
    error_message = "An sfn enrichment must carry a Step Functions state machine ARN, and that state machine must be an EXPRESS workflow: enrichment is a synchronous call, which a Standard workflow cannot serve."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.enrichment == null || try(pipe.enrichment.type, "") != "api-destination" ? true :
        can(regex("^arn:aws[a-zA-Z-]*:events:[a-z0-9-]+:[0-9]{12}:api-destination/", pipe.enrichment.arn))
      )
    ])
    error_message = "An api-destination enrichment must carry an EventBridge API destination ARN."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.enrichment == null || try(pipe.enrichment.http_parameters, null) == null ? true :
        pipe.enrichment.type == "api-destination"
      )
    ])
    error_message = "http_parameters apply only to an api-destination enrichment. A Lambda or state machine enrichment receives the event itself, not an HTTP request."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.enrichment == null || try(pipe.enrichment.input_template, null) == null ? true : alltrue([
          for placeholder in regexall("<([^<>]+)>", pipe.enrichment.input_template) : startswith(placeholder[0], "$")
        ])
      )
    ])
    error_message = "Every placeholder in an enrichment input_template must be a JSON path rooted at $, for example <$.body.orderId>. A pipe template resolves paths directly and has no separate input_paths declaration."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : contains(["lambda", "sqs", "sfn", "bus"], pipe.target.type)
    ])
    error_message = "Target type must be one of lambda, sqs, sfn, or bus."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.type == "bus"
        ? pipe.target.bus != null && pipe.target.arn == null
        : pipe.target.arn != null && pipe.target.bus == null
      )
    ])
    error_message = "A bus target names a key from event_buses and must not set arn. Every other target type sets arn and must not set bus."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.type != "lambda" ? true :
        can(regex("^arn:aws[a-zA-Z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+(:[A-Za-z0-9_$-]+)?$", pipe.target.arn))
      )
    ])
    error_message = "A lambda target must carry a Lambda function ARN, optionally qualified with a version or alias."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.type != "sqs" ? true :
        can(regex("^arn:aws[a-zA-Z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+(\\.fifo)?$", pipe.target.arn))
      )
    ])
    error_message = "An sqs target must carry an SQS queue ARN."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.type != "sfn" ? true :
        can(regex("^arn:aws[a-zA-Z-]*:states:[a-z0-9-]+:[0-9]{12}:stateMachine:[A-Za-z0-9_-]+$", pipe.target.arn))
      )
    ])
    error_message = "An sfn target must carry a Step Functions state machine ARN."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.invocation_type == null ? true : (
          contains(["lambda", "sfn"], pipe.target.type)
          && contains(["REQUEST_RESPONSE", "FIRE_AND_FORGET"], pipe.target.invocation_type)
        )
      )
    ])
    error_message = "invocation_type applies only to a lambda or sfn target and must be REQUEST_RESPONSE or FIRE_AND_FORGET. A REQUEST_RESPONSE state machine target must be an EXPRESS workflow."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.message_group_id == null ? true : (
          pipe.target.type != "sqs" ? false : (
            pipe.target.arn == null ? false : endswith(pipe.target.arn, ".fifo")
          )
        )
      )
    ])
    error_message = "message_group_id applies only to an sqs target whose queue name ends in .fifo."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.type != "sqs" ? true : (
          pipe.target.arn == null ? true : (
            endswith(pipe.target.arn, ".fifo") ? pipe.target.message_group_id != null : true
          )
        )
      )
    ])
    error_message = "A FIFO queue target must declare message_group_id: a FIFO queue rejects a message that arrives without one."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.type == "bus"
        ? pipe.target.detail_type != null && pipe.target.source != null
        : pipe.target.detail_type == null && pipe.target.source == null
      )
    ])
    error_message = "A bus target must declare both detail_type and source, since a pipe delivering onto a bus is publishing a new event that consumers will match on. Neither field applies to any other target type."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.target.input_template == null ? true : alltrue([
          for placeholder in regexall("<([^<>]+)>", pipe.target.input_template) : startswith(placeholder[0], "$")
        ])
      )
    ])
    error_message = "Every placeholder in a target input_template must be a JSON path rooted at $, for example <$.body.orderId>."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : contains(["OFF", "ERROR", "INFO", "TRACE"], pipe.log_level)
    ])
    error_message = "Pipe log_level must be one of OFF, ERROR, INFO, or TRACE."
  }

  validation {
    condition = alltrue([
      for pipe in values(var.pipes) : (
        pipe.include_execution_data ? pipe.log_level != "OFF" : true
      )
    ])
    error_message = "include_execution_data needs a log level other than OFF to write to."
  }
}

variable "pipe_role_arn" {
  description = "ARN of an existing role the pipes should assume. Leave null to let this configuration create one scoped to exactly the declared sources, enrichments, and destinations."
  type        = string
  default     = null

  validation {
    condition     = var.pipe_role_arn == null ? true : can(regex("^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:role/", var.pipe_role_arn))
    error_message = "pipe_role_arn must be an IAM role ARN when set."
  }
}

variable "pipe_log_retention_days" {
  description = "How long pipe execution logs are kept. Failure logs are the record of what a pipe could not deliver, so this outlives a typical debugging session by default."
  type        = number
  default     = 30

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.pipe_log_retention_days
    )
    error_message = "pipe_log_retention_days must be one of the retention periods CloudWatch Logs accepts."
  }
}

variable "pipe_log_kms_key_arn" {
  description = "Key encrypting pipe log groups. Leave null to use the bus key when one exists. Set this when execution data is logged and should be readable under a different key from the events themselves."
  type        = string
  default     = null

  validation {
    condition     = var.pipe_log_kms_key_arn == null ? true : can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.pipe_log_kms_key_arn))
    error_message = "pipe_log_kms_key_arn must be a KMS key ARN when set."
  }
}
