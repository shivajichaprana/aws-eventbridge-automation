terraform {
  required_version = ">= 1.6"

  required_providers {
    # The floor is deliberate: bus-level and archive-level customer managed key
    # support, along with the bus description and dead-letter attributes, are only
    # available from this provider release onward.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80.0, < 6.0.0"
    }
  }
}
