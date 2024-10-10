variable "default_region" {
  description = "AWS region for primary provider"
  type        = string
}

variable "profile" {
  description = "AWS CLI profile to use"
  type        = string
}

variable "vpcs" {
  description = "Map of VPC configurations for multi-VPC deployment"
  type = map(object({
    vpc_cidr    = string
    name_prefix = string
  }))
}
