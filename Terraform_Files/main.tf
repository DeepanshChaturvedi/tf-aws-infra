provider "aws" {
  region  = var.default_region
  profile = var.profile
}

# Fetch up to 3 availability zones for each VPC, or use all if fewer than 3 exist.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Select up to 3 availability zones, converting to a list for compatibility
  selected_zones = slice(sort(data.aws_availability_zones.available.names), 0, min(3, length(data.aws_availability_zones.available.names)))
}

# Loop to create multiple VPCs, with unique identifiers for each instance
module "vpcs" {
  source     = "./vpc_module"
  for_each   = var.vpcs

  region         = var.default_region
  vpc_cidr       = each.value.vpc_cidr
  name_prefix    = each.value.name_prefix
  selected_zones = local.selected_zones
}
