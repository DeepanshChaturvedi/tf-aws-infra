
provider "aws" {
  region  = var.default_region
  profile = var.profile
}

# Fetch available zones
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  selected_zones = slice(sort(data.aws_availability_zones.available.names), 0, min(3, length(data.aws_availability_zones.available.names)))

  # Create a combined map of VPC keys and zones for subnet creation
  vpc_az_combinations = flatten([
    for vpc_key, vpc in var.vpcs : [
      for az in local.selected_zones : {
        vpc_key           = vpc_key
        availability_zone = az
        cidr_index        = index(local.selected_zones, az)
      }
    ]
  ])
}

# Create VPCs
resource "aws_vpc" "vpc" {
  for_each = var.vpcs

  cidr_block           = each.value.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${each.value.name_prefix}-vpc"
  }
}

# Create Internet Gateways
resource "aws_internet_gateway" "igw" {
  for_each = var.vpcs

  vpc_id = aws_vpc.vpc[each.key].id

  tags = {
    Name = "${each.value.name_prefix}-igw"
  }
}

# Create Public Subnets in each VPC and Availability Zone
resource "aws_subnet" "public_subnet" {
  for_each = {
    for idx, item in local.vpc_az_combinations :
    "${item.vpc_key}-${item.availability_zone}-public" => item
  }

  vpc_id                  = aws_vpc.vpc[each.value.vpc_key].id
  cidr_block              = cidrsubnet(var.vpcs[each.value.vpc_key].vpc_cidr, 8, each.value.cidr_index)
  map_public_ip_on_launch = true
  availability_zone       = each.value.availability_zone

  tags = {
    Name = "${var.vpcs[each.value.vpc_key].name_prefix}-public-subnet-${each.value.cidr_index}"
  }
}

# Create Private Subnets in each VPC and Availability Zone
resource "aws_subnet" "private_subnet" {
  for_each = {
    for idx, item in local.vpc_az_combinations :
    "${item.vpc_key}-${item.availability_zone}-private" => item
  }

  vpc_id                  = aws_vpc.vpc[each.value.vpc_key].id
  cidr_block              = cidrsubnet(var.vpcs[each.value.vpc_key].vpc_cidr, 8, length(local.selected_zones) + each.value.cidr_index)
  map_public_ip_on_launch = false
  availability_zone       = each.value.availability_zone

  tags = {
    Name = "${var.vpcs[each.value.vpc_key].name_prefix}-private-subnet-${each.value.cidr_index}"
  }
}

# Public Route Table
resource "aws_route_table" "public_rt" {
  for_each = var.vpcs

  vpc_id = aws_vpc.vpc[each.key].id

  tags = {
    Name = "${each.value.name_prefix}-public-rt"
  }
}

# Add Route to Internet Gateway in the Public Route Table
resource "aws_route" "public_route" {
  for_each               = var.vpcs
  route_table_id         = aws_route_table.public_rt[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw[each.key].id
}

# Associate Public Subnets with Public Route Table
# Associate Public Subnets with Public Route Table
resource "aws_route_table_association" "public_subnet_association" {
  for_each = {
    for key, subnet in aws_subnet.public_subnet :
    key => {
      vpc_key   = split("-", key)[0] # Extract the VPC key from the combined key
      subnet_id = subnet.id
    }
  }

  subnet_id      = each.value.subnet_id
  route_table_id = aws_route_table.public_rt[each.value.vpc_key].id
}


# Create Application Security Group
resource "aws_security_group" "application_sg" {
  for_each    = var.vpcs
  name        = "${each.value.name_prefix}-application-sg"
  description = "Allow SSH, HTTP, HTTPS, and application-specific traffic"
  vpc_id      = aws_vpc.vpc[each.key].id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${each.value.name_prefix}-application-sg"
  }
}

# Create RDS Security Group
resource "aws_security_group" "db_sg" {
  for_each    = var.vpcs
  name        = "${each.value.name_prefix}-database-sg"
  description = "Allow database traffic from application security group"
  vpc_id      = aws_vpc.vpc[each.key].id

  ingress {
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.application_sg[each.key].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${each.value.name_prefix}-database-sg"
  }
}

# Create RDS Parameter Group
resource "aws_db_parameter_group" "db_param_group" {
  name        = "custom-db-parameter-group"
  family      = var.db_family
  description = "Custom parameter group for the database engine"

  parameter {
    name         = "max_connections"
    value        = "100"
    apply_method = "pending-reboot" # Use "pending-reboot" for static parameters
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "0"
    apply_method = "pending-reboot" # Static parameter that requires reboot

  }
}


# Create DB Subnet Group
# Create DB Subnet Group for each VPC
resource "aws_db_subnet_group" "private_db_subnet_group" {
  for_each = var.vpcs

  name = "${each.value.name_prefix}-private-db-subnet-group"

  # Filter private subnets belonging to the current VPC key
  subnet_ids = [
    for key, subnet in aws_subnet.private_subnet :
    subnet.id if startswith(key, each.key)
  ]

  tags = {
    Name = "${each.value.name_prefix}-private-db-subnet-group"
  }
}

# Create RDS Instance
resource "aws_db_instance" "csye6225_rds" {
  for_each               = var.vpcs
  identifier             = "${each.value.name_prefix}-csye6225"
  engine                 = var.db_engine
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  username               = "csye6225"
  password               = var.db_password
  db_name                = "csye6225"
  db_subnet_group_name   = aws_db_subnet_group.private_db_subnet_group[each.key].name
  vpc_security_group_ids = [aws_security_group.db_sg[each.key].id]
  multi_az               = false
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.db_param_group.name
  skip_final_snapshot    = true

  tags = {
    Name = "${each.value.name_prefix}-csye6225-database"
  }
}

# Create EC2 Instance for each VPC
resource "aws_instance" "web_app_instance" {
  for_each               = var.vpcs
  ami                    = var.ami_id
  instance_type          = "t2.micro"
  vpc_security_group_ids = [aws_security_group.application_sg[each.key].id]

  subnet_id = element([
    for key, subnet in aws_subnet.public_subnet :
    subnet.id if startswith(key, each.key)
  ], 0)

  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash

# Define environment variables
DB_INSTANCE="${aws_db_instance.csye6225_rds[each.key].endpoint}"
DB_PORT="${var.db_port}"
DB_NAME="csye6225"
DB_USERNAME="csye6225"
DB_PASSWORD="${var.db_password}"
DB_CONN_STRING="postgres:"

# Create an .env file in the application directory
sudo bash -c 'cat <<EOT > /opt/webapp/.env
DB_INSTANCE=${aws_db_instance.csye6225_rds[each.key].endpoint}
DB_PORT=${var.db_port}
DB_NAME="csye6225"
DB_USERNAME="csye6225"
DB_PASSWORD="${var.db_password}"
DB_CONN_STRING="postgres:"
EOT'

sudo bash -c 'cat <<EOT > /etc/systemd/system/nodeapp.service
[Unit]
Description=Node.js Application
After=network.target

[Service]
ExecStart=/usr/bin/node /opt/webapp/server.js
Restart=always
User=csye6225
EnvironmentFile=/opt/webapp/.env
WorkingDirectory=/opt/webapp

[Install]
WantedBy=multi-user.target

EOT'

# Set correct permissions for the .env file
sudo chown csye6225:csye6225 /opt/webapp/.env
sudo chmod 640 /opt/webapp/.env

# Restart or start your application using SystemD
sudo systemctl daemon-reload
sudo systemctl enable nodeapp
sudo systemctl restart nodeapp
EOF

  tags = {
    Name = "${each.value.name_prefix}-web-app-instance"
  }
}


resource "aws_ami_launch_permission" "share_ami" {
  image_id = var.ami_id # The AMI ID created by Packer or previously defined

  # Add permission for the target AWS account
  account_id = var.target_aws_account_id
}




# Outputs
output "vpc_ids" {
  description = "VPC IDs"
  value       = { for key, vpc in aws_vpc.vpc : key => vpc.id }
}

output "public_subnet_ids" {
  description = "Public Subnet IDs"
  value       = { for key, subnets in aws_subnet.public_subnet : key => subnets.*.id }
}

output "private_subnet_ids" {
  description = "Private Subnet IDs"
  value       = { for key, subnets in aws_subnet.private_subnet : key => subnets.*.id }
}
