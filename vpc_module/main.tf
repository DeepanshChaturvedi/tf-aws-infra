# Create VPC
resource "aws_vpc" "main_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Create Internet Gateway and attach it to the VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# Public Subnets in each selected availability zone
resource "aws_subnet" "public_subnet" {
  count                   = length(var.selected_zones)
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = true
  availability_zone       = element(var.selected_zones, count.index)
  tags = {
    Name = "${var.name_prefix}-public-subnet-${count.index}"
  }
}

# Private Subnets in each selected availability zone
resource "aws_subnet" "private_subnet" {
  count                   = length(var.selected_zones)
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, length(var.selected_zones) + count.index)
  map_public_ip_on_launch = false
  availability_zone       = element(var.selected_zones, count.index)
  tags = {
    Name = "${var.name_prefix}-private-subnet-${count.index}"
  }
}

# Public Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id
  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

# Add Route to Internet Gateway in the Public Route Table
resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Associate Public Subnets with Public Route Table
resource "aws_route_table_association" "public_subnet_association" {
  count          = length(var.selected_zones)
  subnet_id      = element(aws_subnet.public_subnet[*].id, count.index)
  route_table_id = aws_route_table.public_rt.id
}

# Private Route Table (no route to Internet Gateway)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main_vpc.id
  tags = {
    Name = "${var.name_prefix}-private-rt"
  }
}

# Associate Private Subnets with Private Route Table
resource "aws_route_table_association" "private_subnet_association" {
  count          = length(var.selected_zones)
  subnet_id      = element(aws_subnet.private_subnet[*].id, count.index)
  route_table_id = aws_route_table.private_rt.id
}
