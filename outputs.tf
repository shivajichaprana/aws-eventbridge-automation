output "event_bus_names" {
  description = "Created event bus names, keyed by the unprefixed bus key."
  value       = { for name, bus in aws_cloudwatch_event_bus.this : name => bus.name }
}

output "event_bus_arns" {
  description = "Created event bus ARNs, keyed by the unprefixed bus key. Rules, pipes, and cross-account grants attach to these."
  value       = { for name, bus in aws_cloudwatch_event_bus.this : name => bus.arn }
}

output "archive_names" {
  description = "Archive names, keyed by the bus they buffer. Use these to start a replay."
  value       = { for name, archive in aws_cloudwatch_event_archive.this : name => archive.name }
}

output "archive_arns" {
  description = "Archive ARNs, keyed by the bus they buffer."
  value       = { for name, archive in aws_cloudwatch_event_archive.this : name => archive.arn }
}

output "archive_retention_days" {
  description = "Retention window in force for each archive, so downstream runbooks can state how far back a replay can reach."
  value       = { for name, archive in aws_cloudwatch_event_archive.this : name => archive.retention_days }
}

output "kms_key_arn" {
  description = "ARN of the key protecting bus and archive contents, whether created here or supplied."
  value       = local.bus_key_arn
}

output "kms_key_alias" {
  description = "Alias of the managed encryption key, or null when an existing key was supplied."
  value       = one(aws_kms_alias.events[*].name)
}

output "schema_registry_name" {
  description = "Name of the curated contract registry, or null when the registry is disabled."
  value       = one(aws_schemas_registry.contracts[*].name)
}

output "schema_registry_arn" {
  description = "ARN of the curated contract registry, or null when the registry is disabled."
  value       = one(aws_schemas_registry.contracts[*].arn)
}

output "contract_schema_names" {
  description = "Registered contract schema names, keyed by contract file stem."
  value       = { for key, schema in aws_schemas_schema.contract : key => schema.name }
}

output "schema_discoverer_ids" {
  description = "Discoverer identifiers, keyed by the bus whose traffic they inspect."
  value       = { for name, discoverer in aws_schemas_discoverer.this : name => discoverer.id }
}

output "event_rule_names" {
  description = "Created rule names, keyed by the unprefixed rule key."
  value       = { for key, rule in aws_cloudwatch_event_rule.this : key => rule.name }
}

output "event_rule_arns" {
  description = "Created rule ARNs, keyed by the unprefixed rule key. Target resource policies scope to these."
  value       = { for key, rule in aws_cloudwatch_event_rule.this : key => rule.arn }
}

output "event_rule_target_ids" {
  description = "Target identifiers attached to each rule, keyed by rule key."
  value = {
    for rule_key in keys(var.event_rules) : rule_key => sort([
      for target_key, target in local.rule_targets : target.target_key if target.rule_key == rule_key
    ])
  }
}

output "rule_dead_letter_queue_arns" {
  description = "Managed undeliverable-event queue ARNs, keyed by the rule that owns each one."
  value       = local.managed_dlq_arns
}

output "rule_dead_letter_queue_urls" {
  description = "Managed undeliverable-event queue URLs, keyed by rule key, for draining or redriving during an incident."
  value       = { for key, queue in aws_sqs_queue.rule_dlq : key => queue.url }
}

output "targets_without_dead_letter_queue" {
  description = "Rule/target pairs with nowhere to send a failed delivery. Empty unless managed queues are disabled without an explicit replacement."
  value       = local.targets_without_dead_letter
}

output "step_functions_invocation_role_arn" {
  description = "Role EventBridge assumes to start state machine targets, whether created here or supplied. Null when no state machine target is declared."
  value       = local.states_role_arn
}
