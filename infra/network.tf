resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "twelve-dollar" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "twelve-dollar" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = var.az
  map_public_ip_on_launch = true
  tags                    = { Name = "twelve-dollar-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "twelve-dollar-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_key_pair" "operator" {
  key_name   = "twelve-dollar-operator"
  public_key = file(pathexpand(var.ssh_pubkey_path))
}

# Port 80 open to the world with unrestricted egress makes those flows *untracked* by security-group
# connection tracking, so the per-instance tracking allowance can't cap us at tens of thousands of
# keep-alive connections. SSH stays restricted to the operator.
resource "aws_security_group" "target" {
  name   = "twelve-dollar-target"
  vpc_id = aws_vpc.this.id
  tags   = { Name = "twelve-dollar-target" }
}

resource "aws_vpc_security_group_ingress_rule" "target_ssh" {
  security_group_id = aws_security_group.target.id
  cidr_ipv4         = "${var.my_ip}/32"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "target_http" {
  security_group_id = aws_security_group.target.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "target_all" {
  security_group_id = aws_security_group.target.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "loadgen" {
  name   = "twelve-dollar-loadgen"
  vpc_id = aws_vpc.this.id
  tags   = { Name = "twelve-dollar-loadgen" }
}

resource "aws_vpc_security_group_ingress_rule" "loadgen_ssh" {
  security_group_id = aws_security_group.loadgen.id
  cidr_ipv4         = "${var.my_ip}/32"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "loadgen_all" {
  security_group_id = aws_security_group.loadgen.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
