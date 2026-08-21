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
