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

output "pipe_names" {
  description = "Created pipe names, keyed by the unprefixed pipe key."
  value       = { for key, pipe in aws_pipes_pipe.this : key => pipe.name }
}

output "pipe_arns" {
  description = "Created pipe ARNs, keyed by the unprefixed pipe key."
  value       = { for key, pipe in aws_pipes_pipe.this : key => pipe.arn }
}

output "pipe_desired_states" {
  description = "Whether each pipe is set to run or stay stopped, so a review can see at a glance which connectors are actually draining a queue."
  value       = { for key, pipe in aws_pipes_pipe.this : key => pipe.desired_state }
}

output "pipe_source_queue_arns" {
  description = "Source queue each pipe consumes, keyed by pipe key. Confirm every one of these carries a redrive policy: a pipe has no dead-letter configuration of its own."
  value       = { for key, pipe in var.pipes : key => pipe.source_queue_arn }
}

output "pipe_log_group_names" {
  description = "Execution log group per pipe, keyed by pipe key. Absent for a pipe with logging turned off."
  value       = { for key, group in aws_cloudwatch_log_group.pipe : key => group.name }
}

output "pipe_role_arn" {
  description = "Role the pipes run as, whether created here or supplied. Null when no pipe is declared."
  value       = local.pipes_role_arn
}

output "pipes_with_unfiltered_source" {
  description = "Pipes carrying every message their source queue receives. Empty unless a pipe deliberately declares no filter patterns."
  value       = sort([for key, pipe in var.pipes : key if length(pipe.filter_patterns) == 0])
}

output "schedule_group_names" {
  description = "Created schedule group names, keyed by the unprefixed group key."
  value       = local.schedule_group_names
}

output "schedule_names" {
  description = "Created schedule names, keyed by the unprefixed schedule key."
  value       = { for key, schedule in aws_scheduler_schedule.this : key => schedule.name }
}

output "schedule_arns" {
  description = "Created schedule ARNs, keyed by the unprefixed schedule key."
  value       = { for key, schedule in aws_scheduler_schedule.this : key => schedule.arn }
}

output "schedule_states" {
  description = "Whether each schedule is set to run, so a review can see at a glance which clocks are actually ticking."
  value       = { for key, schedule in aws_scheduler_schedule.this : key => schedule.state }
}

output "schedule_role_arn" {
  description = "Role the schedules run as, whether created here or supplied. Null when no schedule is declared."
  value       = local.schedule_role_arn
}

output "schedule_kms_key_arn" {
  description = "Key encrypting the stored target payload of every schedule, whether the bus key or one supplied for the purpose."
  value       = local.schedule_key_arn
}

output "schedules_without_dead_letter_queue" {
  description = "Schedules with nowhere to record an invocation that never succeeded. A missed run leaves no other trace, so anything here should be a deliberate choice."
  value       = local.schedules_without_dead_letter
}

output "cross_account_bus_grants" {
  description = "Who may publish onto each bus from outside this account, keyed by bus key, with the event shapes each grant is narrowed to. Empty for a bus that accepts events only from its own account."
  value = {
    for key, cfg in local.cross_account_buses : key => {
      named_principals     = sort(local.cross_account_named_principals[key])
      organization_id      = cfg.organization_id
      allowed_sources      = sort(cfg.allowed_sources)
      allowed_detail_types = sort(cfg.allowed_detail_types)
      rule_management      = cfg.allow_rule_management
    }
  }
}

output "cross_account_forwarding_rule_names" {
  description = "Created forwarding rule names, keyed by the unprefixed forwarding key."
  value       = { for key, rule in aws_cloudwatch_event_rule.cross_account_forwarding : key => rule.name }
}

output "cross_account_forwarding_rule_arns" {
  description = "Created forwarding rule ARNs, keyed by the unprefixed forwarding key."
  value       = { for key, rule in aws_cloudwatch_event_rule.cross_account_forwarding : key => rule.arn }
}

output "cross_account_forwarding_destinations" {
  description = "Remote buses each forwarding rule publishes to, keyed by forwarding key. Every one of these needs a matching grant in the account that owns it before delivery succeeds."
  value       = { for key, fwd in var.cross_account_forwarding : key => sort(fwd.destination_bus_arns) }
}

output "cross_account_forwarding_role_arn" {
  description = "Role EventBridge assumes to publish onto remote buses, whether created here or supplied. Null when no forwarding rule is declared."
  value       = local.forwarding_role_arn
}

output "cross_account_forwarding_without_dead_letter_queue" {
  description = "Forwarding rules with nowhere to send a delivery the receiving account refused. Cross-account delivery fails for reasons outside this account's control, so anything here fails silently."
  value       = local.forwarding_without_dead_letter
}
