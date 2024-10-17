variable "default_region" {
  description = "AWS region for primary provider"
  type        = string
}

variable "profile" {
  description = "AWS CLI profile to use"
  type        = string
}

# variable "vpcs" {
#   description = "Map of VPC configurations for multi-VPC deployment"
#   type = map(object({
#     vpc_cidr    = string
#     name_prefix = string
#   }))
# }

variable "ami_id" {
  description = "The ID of the custom AMI to use for the EC2 instance"
  type        = string
}

variable "application_port" {
  description = "The port on which the application runs"
  type        = number
  default     = 8000  # Default is set to 8080; change as necessary
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# The CIDR block for the public subnet
variable "subnet_cidr" {
  description = "The CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# The AWS region for the deployment
variable "region" {
  description = "The AWS region for the deployment"
  type        = string
  default     = "us-east-1"
}