# output "vpc_ids" {
#   description = "VPC IDs from all modules"
#   value       = { for k, v in module.vpcs : k => v.vpc_id }
# }

# output "public_subnet_ids" {
#   description = "Public subnet IDs from all modules"
#   value       = { for k, v in module.vpcs : k => v.public_subnet_ids }
# }

# output "private_subnet_ids" {
#   description = "Private subnet IDs from all modules"
#   value       = { for k, v in module.vpcs : k => v.private_subnet_ids }
# }
