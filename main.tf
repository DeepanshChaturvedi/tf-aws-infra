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
  for_each             = var.vpcs
  cidr_block           = each.value.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${each.value.name_prefix}-vpc" }
}

# Create Internet Gateways
resource "aws_internet_gateway" "igw" {
  for_each = var.vpcs
  vpc_id   = aws_vpc.vpc[each.key].id
  tags     = { Name = "${each.value.name_prefix}-igw" }
}

# Public and Private Subnets
resource "aws_subnet" "public_subnet" {
  for_each = {
    for idx, item in local.vpc_az_combinations :
    "${item.vpc_key}-${item.availability_zone}-public" => item
  }
  vpc_id                  = aws_vpc.vpc[each.value.vpc_key].id
  cidr_block              = cidrsubnet(var.vpcs[each.value.vpc_key].vpc_cidr, 8, each.value.cidr_index)
  map_public_ip_on_launch = true
  availability_zone       = each.value.availability_zone
  tags                    = { Name = "${var.vpcs[each.value.vpc_key].name_prefix}-public-subnet-${each.value.cidr_index}" }
}

resource "aws_subnet" "private_subnet" {
  for_each = {
    for idx, item in local.vpc_az_combinations :
    "${item.vpc_key}-${item.availability_zone}-private" => item
  }
  vpc_id                  = aws_vpc.vpc[each.value.vpc_key].id
  cidr_block              = cidrsubnet(var.vpcs[each.value.vpc_key].vpc_cidr, 8, length(local.selected_zones) + each.value.cidr_index)
  map_public_ip_on_launch = false
  availability_zone       = each.value.availability_zone
  tags                    = { Name = "${var.vpcs[each.value.vpc_key].name_prefix}-private-subnet-${each.value.cidr_index}" }
}

# Public Route Table
resource "aws_route_table" "public_rt" {
  for_each = var.vpcs
  vpc_id   = aws_vpc.vpc[each.key].id
  tags     = { Name = "${each.value.name_prefix}-public-rt" }
}

resource "aws_route" "public_route" {
  for_each               = var.vpcs
  route_table_id         = aws_route_table.public_rt[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw[each.key].id
}

resource "aws_route_table_association" "public_subnet_association" {
  for_each = {
    for key, subnet in aws_subnet.public_subnet :
    key => { vpc_key = split("-", key)[0], subnet_id = subnet.id }
  }
  subnet_id      = each.value.subnet_id
  route_table_id = aws_route_table.public_rt[each.value.vpc_key].id
}

# Security Groups
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

  ingress {
    from_port   = 8125
    to_port     = 8125
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = var.application_port
    to_port     = var.application_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${each.value.name_prefix}-application-sg" }
}

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
  tags = { Name = "${each.value.name_prefix}-database-sg" }
}

# RDS Parameter Group
resource "aws_db_parameter_group" "db_param_group" {
  name        = "custom-db-parameter-group"
  family      = var.db_family
  description = "Custom parameter group for the database engine"
  parameter {
    name         = "max_connections"
    value        = "100"
    apply_method = "pending-reboot"
  }
  parameter {
    name         = "rds.force_ssl"
    value        = "0"
    apply_method = "pending-reboot"
  }
}

# DB Subnet Group
resource "aws_db_subnet_group" "private_db_subnet_group" {
  for_each = var.vpcs
  name     = "${each.value.name_prefix}-private-db-subnet-group"
  subnet_ids = [
    for key, subnet in aws_subnet.private_subnet :
    subnet.id if startswith(key, each.key)
  ]
  tags = { Name = "${each.value.name_prefix}-private-db-subnet-group" }
}

# RDS Instance
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
  tags                   = { Name = "${each.value.name_prefix}-csye6225-database" }
}

# IAM Role and Policy for EC2 to access S3
resource "aws_iam_role" "ec2_s3_access_role" {
  name = "ec2_s3_access_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "s3_access_policy" {
  name = "ec2_s3_access_policy"
  role = aws_iam_role.ec2_s3_access_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource = [
          "${aws_s3_bucket.attachments_bucket.arn}",
          "${aws_s3_bucket.attachments_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2_instance_profile"
  role = aws_iam_role.ec2_s3_access_role.name
}

# Define the IAM Role for EC2 with combined S3 and CloudWatch permissions
resource "aws_iam_role" "combined_ec2_role" {
  name = "combined_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Define the combined IAM policy for S3 and CloudWatch permissions
resource "aws_iam_policy" "combined_policy" {
  name        = "combined_policy_for_ec2"
  description = "Policy with permissions for S3 access and CloudWatch metrics/logs"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # CloudWatch permissions
      {
        Effect = "Allow",
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricStatistics",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups"
        ],
        Resource = "*"
      },
      # S3 permissions
      {
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource = [
          "${aws_s3_bucket.attachments_bucket.arn}",
          "${aws_s3_bucket.attachments_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "webapp_info_log_group" {
  name              = "webapp-info-logs"
  retention_in_days = 3  # Specify retention period as needed
}

resource "aws_cloudwatch_log_group" "webapp_error_log_group" {
  name              = "webapp-error-logs"
  retention_in_days = 3  # Specify retention period as needed
}


# Attach the combined policy to the IAM role
resource "aws_iam_role_policy_attachment" "combined_policy_attachment" {
  role       = aws_iam_role.combined_ec2_role.name
  policy_arn = aws_iam_policy.combined_policy.arn
}

# Create an instance profile and associate it with the combined IAM role
resource "aws_iam_instance_profile" "combined_instance_profile" {
  name = "combined_instance_profile"
  role = aws_iam_role.combined_ec2_role.name
}

# S3 Bucket
resource "random_uuid" "bucket_id" {}

resource "aws_s3_bucket" "attachments_bucket" {
  bucket        = "attachments-${random_uuid.bucket_id.result}"
  force_destroy = true
  tags          = { Name = "Attachments Bucket" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "attachments_bucket_encryption" {
  bucket = aws_s3_bucket.attachments_bucket.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "attachments_bucket_lifecycle" {
  bucket = aws_s3_bucket.attachments_bucket.id
  rule {
    id     = "transition-to-standard-ia"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}

resource "aws_route53_record" "app_a_record" {
  for_each = aws_instance.web_app_instance

  zone_id = var.route53_zone_id
  name    = "${var.subdomain}.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [each.value.public_ip] # Use each.value to access the IP
}

# EC2 Instance with S3 and RDS Environment Variables
resource "aws_instance" "web_app_instance" {
  for_each               = var.vpcs
  ami                    = var.ami_id
  instance_type          = "t2.micro"
  vpc_security_group_ids = [aws_security_group.application_sg[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.combined_instance_profile.name

  subnet_id = element([
    for key, subnet in aws_subnet.public_subnet :
    subnet.id if startswith(key, each.key)
  ], 0)

  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash
set -e
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# Environment Variables
DB_INSTANCE="${aws_db_instance.csye6225_rds[each.key].endpoint}"
DB_PORT="${var.db_port}"
DB_NAME="csye6225"
DB_USERNAME="csye6225"
DB_PASSWORD="${var.db_password}"
DB_CONN_STRING="postgres:"
S3_BUCKET_NAME="${aws_s3_bucket.attachments_bucket.bucket}"
AWS_REGION="${var.default_region}"
APP_DOMAIN="${var.subdomain}.${var.domain}"

# Create .env file for application
sudo bash -c 'cat <<EOT > /opt/webapp/.env
DB_INSTANCE=${aws_db_instance.csye6225_rds[each.key].endpoint}
DB_PORT=${var.db_port}
DB_NAME="csye6225"
DB_USERNAME="csye6225"
DB_PASSWORD="${var.db_password}"
DB_CONN_STRING="postgres:"
S3_BUCKET_NAME="${aws_s3_bucket.attachments_bucket.bucket}"
AWS_REGION="${var.default_region}"
APP_DOMAIN="${var.subdomain}.${var.domain}"
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

# Set permissions and start application
sudo chown csye6225:csye6225 /opt/webapp/.env
sudo chmod 640 /opt/webapp/.env
sudo systemctl daemon-reload
sudo systemctl enable nodeapp
sudo systemctl restart nodeapp

# Create CloudWatch Agent configuration file
sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat <<EOL | sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null
{
  "agent": {
      "metrics_collection_interval": 10,
      "logfile": "/var/log/amazon-cloudwatch-agent.log"
  },
  "logs": {
      "logs_collected": {
          "files": {
              "collect_list": [
                  {
                      "file_path": "/opt/webapp/logs/app.log",
                      "log_group_name": "webapp-logs",
                      "log_stream_name": "webapp",
                      "timestamp_format": "%Y-%m-%d %H:%M:%S"
                  },
                  {
                      "file_path": "/opt/webapp/logs/error.log",
                      "log_group_name": "webapp-error-logs",
                      "log_stream_name": "webapp",
                      "timestamp_format": "%Y-%m-%d %H:%M:%S"
                  }
              ]
          }
      }
  },
  "metrics": {
    "metrics_collected": {
      "statsd": {
        "service_address": ":8125",
        "metrics_collection_interval": 10,
        "metrics_aggregation_interval": 60
      }
    }
  }
}
EOL

# Start CloudWatch Agent with the configuration file
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
  sudo systemctl restart amazon-cloudwatch-agent


EOF

  tags = { Name = "${each.value.name_prefix}-web-app-instance" }
}

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

output "app_url" {
  description = "URL of the application"
  value       = "http://${var.subdomain}.${var.domain}:${var.app_port}"
}
