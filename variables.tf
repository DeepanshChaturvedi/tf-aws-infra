# AWS Region and Profile
variable "default_region" {
  description = "AWS region for primary provider"
  type        = string
}

variable "profile" {
  description = "AWS CLI profile to use"
  type        = string
}

# VPC Configurations
variable "vpcs" {
  description = "Map of VPC configurations for multi-VPC deployment"
  type = map(object({
    vpc_cidr    = string
    name_prefix = string
  }))
}

# AMI Configurations
variable "ami_id" {
  description = "The ID of the custom AMI to use for the EC2 instance"
  type        = string
}

# Application Configurations
variable "application_port" {
  description = "The port on which the application runs"
  type        = number
  default     = 8000 # Default is set to 8000; change as necessary
}

# VPC and Subnet CIDR Blocks
variable "vpc_cidr" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "The CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "The CIDR block for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

# Database Configuration
variable "db_engine" {
  description = "The database engine for RDS (mysql, postgres, or mariadb)"
  type        = string
  default     = "postgres"
}

variable "db_port" {
  description = "The database port (default 3306 for MySQL/MariaDB, 5432 for PostgreSQL)"
  type        = number
  default     = 5432 # Update based on your database engine
}

variable "db_family" {
  description = "The database parameter group family (mysql8.0, postgres12, etc.)"
  type        = string
  default     = "postgres12" # Update based on your engine and version
}

variable "db_password" {
  description = "The password for the database master user"
  type        = string
}

# Additional Configurations
variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}
