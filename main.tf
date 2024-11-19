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

# Load Balancer Security Group
resource "aws_security_group" "load_balancer_sg" {
  for_each    = var.vpcs
  name        = "${each.value.name_prefix}-load-balancer-sg"
  description = "Security group for Load Balancer"
  vpc_id      = aws_vpc.vpc[each.key].id

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
}

# Application Security Group
resource "aws_security_group" "application_sg" {
  for_each    = var.vpcs
  name        = "${each.value.name_prefix}-application-sg"
  description = "Allow traffic only from Load Balancer"
  vpc_id      = aws_vpc.vpc[each.key].id

  ingress {
    from_port       = var.application_port
    to_port         = var.application_port
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_sg[each.key].id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Role for EC2 instances to access S3 and CloudWatch
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

# IAM Policy with permissions for S3 and CloudWatch
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

resource "aws_iam_policy" "ec2_sns_publish_policy" {
  name        = "ec2_sns_publish_policy"
  description = "Policy for EC2 instances to publish messages to SNS"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "sns:Publish",
        Resource = aws_sns_topic.user_creation_topic.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_sns_publish_policy_attachment" {
  role       = aws_iam_role.combined_ec2_role.name
  policy_arn = aws_iam_policy.ec2_sns_publish_policy.arn
}


# Attach the combined policy to the IAM role
resource "aws_iam_role_policy_attachment" "combined_policy_attachment" {
  role       = aws_iam_role.combined_ec2_role.name
  policy_arn = aws_iam_policy.combined_policy.arn
}

# Create an instance profile to attach the IAM role to EC2 instances
resource "aws_iam_instance_profile" "combined_instance_profile" {
  name = "combined_instance_profile"
  role = aws_iam_role.combined_ec2_role.name
}

# S3 Bucket for Attachments
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


# Database Security Group
resource "aws_security_group" "db_sg" {
  for_each    = var.vpcs
  name        = "${each.value.name_prefix}-database-sg"
  description = "Allow database traffic from application security group"
  vpc_id      = aws_vpc.vpc[each.key].id # Ensure it matches the VPC for this RDS instance

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

# Create Load Balancer
resource "aws_lb" "app_lb" {
  name               = "${var.profile}-app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer_sg["vpc1"].id] # Ensure to use the correct VPC key here
  subnets            = [for subnet in aws_subnet.public_subnet : subnet.id]

  enable_deletion_protection = false
  tags = {
    Name = "${var.profile}-app-lb"
  }
}


resource "aws_lb_target_group" "app_target_group" {
  for_each = var.vpcs
  name     = "${var.profile}-app-tg"
  port     = var.application_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc[each.key].id # Replace "vpc1" with your actual key

  health_check {
    path                = "/healthz"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "${var.profile}-app-target-group"
  }
}

resource "aws_autoscaling_attachment" "asg_attachment" {
  for_each               = var.vpcs # Loop over each VPC to create an attachment per Auto Scaling Group
  autoscaling_group_name = aws_autoscaling_group.web_app_asg[each.key].name
  lb_target_group_arn    = aws_lb_target_group.app_target_group[each.key].arn
}


resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn # Direct reference to the single load balancer
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_target_group["vpc1"].arn # Use a specific key for target group if necessary
  }
}



resource "aws_route53_record" "app_a_record" {
  zone_id = var.route53_zone_id
  name    = "${var.subdomain}.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.app_lb.dns_name # Point to the ALB's DNS name
    zone_id                = aws_lb.app_lb.zone_id  # Use the ALB's hosted zone ID
    evaluate_target_health = true
  }
}


# Launch Template for Auto Scaling Group
resource "aws_launch_template" "web_app_launch_template" {
  for_each      = var.vpcs
  name_prefix   = "csye6225_asg"
  image_id      = var.ami_id
  instance_type = "t2.micro"
  key_name      = var.key_name

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.application_sg[each.key].id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.combined_instance_profile.name
  }

  user_data = base64encode(<<-EOF
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
SNS_TOPIC_ARN="${aws_sns_topic.user_creation_topic.arn}"

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
SNS_TOPIC_ARN="${aws_sns_topic.user_creation_topic.arn}"
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
  )
}



# Auto Scaling Group
resource "aws_autoscaling_group" "web_app_asg" {
  for_each = var.vpcs
  launch_template {
    id      = aws_launch_template.web_app_launch_template[each.key].id
    version = "$Latest"
  }

  min_size                  = 3                                                    # Minimum number of instances
  max_size                  = 5                                                    # Maximum number of instances
  desired_capacity          = 3                                                    # Initial number of instances to launch
  vpc_zone_identifier       = [for subnet in aws_subnet.public_subnet : subnet.id] # Subnets where instances will be launched
  health_check_type         = "EC2"
  health_check_grace_period = 60 # Grace period for health checks
  default_instance_warmup   = 8

  # Tags applied to EC2 instances
  tag {
    key                 = "Name"
    value               = "${each.value.name_prefix}-web-app-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.profile # Additional tag example
    propagate_at_launch = true
  }

  tag {
    key                 = "AutoScalingGroup"
    value               = "${each.value.name_prefix}-asg"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}



# Auto Scaling Policies
# Scale Up Policy - Increases the instance count by 1
resource "aws_autoscaling_policy" "scale_up" {
  for_each               = var.vpcs
  name                   = "${each.value.name_prefix}-scale-up-policy"
  autoscaling_group_name = aws_autoscaling_group.web_app_asg[each.key].name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1  # Increment by 1 instance
  cooldown               = 60 # Cooldown period
}

# Scale Down Policy - Decreases the instance count by 1
resource "aws_autoscaling_policy" "scale_down" {
  for_each               = var.vpcs
  name                   = "${each.value.name_prefix}-scale-down-policy"
  autoscaling_group_name = aws_autoscaling_group.web_app_asg[each.key].name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1 # Decrement by 1 instance
  cooldown               = 60 # Cooldown period

}

# CloudWatch Alarm for Scaling Up
resource "aws_cloudwatch_metric_alarm" "scale_up_alarm" {
  for_each            = var.vpcs
  alarm_name          = "${each.value.name_prefix}-scale-up-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 9.0 # Scale up when CPU > 8%
  alarm_description   = "Alarm to scale up when CPU utilization is above 9%"
  alarm_actions       = [aws_autoscaling_policy.scale_up[each.key].arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_app_asg[each.key].name
  }
}

# CloudWatch Alarm for Scaling Down
resource "aws_cloudwatch_metric_alarm" "scale_down_alarm" {
  for_each            = var.vpcs
  alarm_name          = "${each.value.name_prefix}-scale-down-alarm"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 7.0 # Scale down when CPU < 7%
  alarm_description   = "Alarm to scale down when CPU utilization is below 7%"
  alarm_actions       = [aws_autoscaling_policy.scale_down[each.key].arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_app_asg[each.key].name
  }
}

resource "aws_sns_topic" "user_creation_topic" {
  name = var.sns_topic_name
}
resource "aws_iam_role" "lambda_execution_role" {
  name = "lambda_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "lambda_policy"
  description = "Policy for Lambda to access SNS and CloudWatch"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "sns:Publish",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_lambda_function" "email_verification_lambda" {
  for_each         = aws_db_instance.csye6225_rds
  function_name    = "email_verification_lambda_${each.key}"
  filename         = var.lambda_zip_path
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  role             = aws_iam_role.lambda_execution_role.arn
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  environment {
    variables = {
      MAILGUN_API_KEY = var.email_server["api_key"]
      MAILGUN_DOMAIN  = var.email_server["domain"]
      APP_DOMAIN      = "${var.subdomain}.${var.domain}"
      DB_NAME         = "csye6225"
      DB_CONN_STRING  = "${each.value.endpoint}"
      DB_USERNAME     = "csye6225"
      DB_PASSWORD     = "${var.db_password}"
    }
  }

  tags = {
    Name = "email_verification_lambda"
  }
}

resource "aws_sns_topic_subscription" "lambda_subscription" {
  for_each  = aws_lambda_function.email_verification_lambda
  topic_arn = aws_sns_topic.user_creation_topic.arn
  protocol  = "lambda"
  endpoint  = each.value.arn
}

resource "aws_lambda_permission" "allow_sns_invoke" {
  for_each      = aws_lambda_function.email_verification_lambda
  statement_id  = "AllowSNSInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.user_creation_topic.arn
}

output "sns_topic_arn" {
  value       = aws_sns_topic.user_creation_topic.arn
  description = "ARN of the SNS topic"
}

output "lambda_function_arns" {
  value       = [for lambda in aws_lambda_function.email_verification_lambda : lambda.arn]
  description = "List of ARNs for all Lambda functions"
}

