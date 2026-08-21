# EventBridge is a regional service: a bus, its rules, and its archive all live in one
# region. Deploy this configuration once per region that needs to accept events, and use
# cross-region routing rather than trying to span a single bus across regions.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.default_tags
  }
}
