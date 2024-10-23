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
  source   = "./vpc_module"
  for_each = var.vpcs

  region         = var.default_region
  vpc_cidr       = each.value.vpc_cidr
  name_prefix    = each.value.name_prefix
  selected_zones = local.selected_zones
}

# Create VPC
resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "app-vpc"
  }
}

# Create a Public Subnet in the VPC
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = var.subnet_cidr
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

# Internet Gateway for VPC
resource "aws_internet_gateway" "app_igw" {
  vpc_id = aws_vpc.app_vpc.id

  tags = {
    Name = "app-igw"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app_igw.id
  }

  tags = {
    Name = "public-route-table"
  }
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "public_route_table_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

# Security Group for Application
resource "aws_security_group" "application_sg" {
  name        = "application_security_group"
  description = "Allow SSH, HTTP, HTTPS, and application-specific traffic"
  vpc_id      = aws_vpc.app_vpc.id

  # Allow SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTP access
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS access
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow application-specific port access
  ingress {
    from_port   = var.application_port
    to_port     = var.application_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "application-security-group"
  }
}


# Security Group for RDS Database
resource "aws_security_group" "db_sg" {
  name        = "database-security-group"
  description = "Allow MySQL/PostgreSQL traffic from application security group"
  vpc_id      = aws_vpc.app_vpc.id

  # Allow MySQL or PostgreSQL traffic from the application security group
  ingress {
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.application_sg.id]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "database-security-group"
  }
}

resource "aws_db_parameter_group" "db_param_group" {
  name        = "custom-db-parameter-group"
  family      = "postgres12"
  description = "Custom parameter group for MySQL or PostgreSQL"

  parameter {
    name  = "max_connections"
    value = "100"
  }
}

resource "aws_db_instance" "csye6225_rds" {
  identifier             = "csye6225"
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  name                   = "csye6225"
  username               = "csye6225"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.private_db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  multi_az               = false
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.db_param_group.name

  tags = {
    Name = "csye6225-database"
  }
}

resource "aws_db_subnet_group" "private_db_subnet_group" {
  name       = "private-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "private-db-subnet-group"
  }
}

# EC2 Instance
resource "aws_instance" "web_app_instance" {
  ami                         = var.ami_id
  instance_type               = "t2.micro" # Update instance type as needed
  vpc_security_group_ids      = [aws_security_group.application_sg.id]
  subnet_id                   = aws_subnet.public_subnet.id
  associate_public_ip_address = true

  # Enable termination protection
  disable_api_termination = false

  # Configure root EBS volume
  root_block_device {
    volume_size           = 25
    volume_type           = "gp2"
    delete_on_termination = true
  }

  # User Data Script for environment variables and application start
  user_data = <<EOF
#!/bin/bash
echo "DB_HOST=${aws_db_instance.csye6225_rds.endpoint}" >> /etc/environment
echo "DB_NAME=csye6225" >> /etc/environment
echo "DB_USERNAME=csye6225" >> /etc/environment
echo "DB_PASSWORD=${var.db_password}" >> /etc/environment

source /etc/environment

# Run your web app's start command or systemd service start
systemctl restart nodeapp
EOF

  tags = {
    Name = "web-app-instance"
  }
}