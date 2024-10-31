# Variables File (variables.tf)

variable "default_region" {
  description = "AWS region for primary provider"
  type        = string
}

variable "profile" {
  description = "AWS CLI profile to use"
  type        = string
}

variable "ami_id" {
  description = "The ID of the custom AMI to use for the EC2 instance"
  type        = string
}

variable "application_port" {
  description = "The port on which the application runs"
  type        = number
  default     = 8000 # Update based on your app requirements
}

variable "vpcs" {
  description = "Map of VPC configurations for multi-VPC deployment"
  type = map(object({
    vpc_cidr    = string
    name_prefix = string
  }))
}

variable "db_engine" {
  description = "The database engine for RDS (mysql, postgres, or mariadb)"
  type        = string
  default     = "postgres"
}

variable "db_port" {
  description = "The database port (default 3306 for MySQL/MariaDB, 5432 for PostgreSQL)"
  type        = number
  default     = 5432
}

variable "db_family" {
  description = "The database parameter group family (e.g., postgres12, mysql8.0)"
  type        = string
  default     = "postgres12"
}

variable "db_password" {
  description = "The password for the database master user"
  type        = string
}

variable "target_aws_account_id" {
  description = "The AWS account ID with which to share the AMI"
  type        = string
}

variable "route53_zone_id" {
  description = "The Route53 Zone ID for DNS management"
  type        = string
}

variable "domain" {
  description = "The domain name to use for the application"
  type        = string
}

variable "subdomain" {
  description = "The subdomain prefix for the environment (e.g., dev, demo)"
  type        = string
  default     = "dev" # or "demo" depending on the environment
}

variable "app_port" {
  description = "The port on which the application listens"
  type        = number
  default     = 8000 # update to the actual port number if different
}