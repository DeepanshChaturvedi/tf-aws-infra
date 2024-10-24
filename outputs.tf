# # Outputs File (outputs.tf)

# output "vpc_id" {
#   description = "The ID of the VPC"
#   value       = aws_vpc.main_vpc.id
# }

# output "public_subnet_ids" {
#   description = "List of public subnet IDs"
#   value       = aws_subnet.public_subnet[*].id
# }

# output "private_subnet_ids" {
#   description = "List of private subnet IDs"
#   value       = aws_subnet.private_subnet[*].id
# }

# output "application_sg_id" {
#   description = "The ID of the application security group"
#   value       = aws_security_group.application_sg.id
# }

# output "rds_endpoint" {
#   description = "The RDS instance endpoint"
#   value       = aws_db_instance.csye6225_rds.endpoint
# }
