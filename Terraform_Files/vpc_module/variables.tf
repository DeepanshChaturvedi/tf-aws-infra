variable "region" {
  description = "AWS region for resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for naming resources"
  type        = string
}

variable "selected_zones" {
  description = "List of availability zones for subnets"
  type        = list(string)
}
