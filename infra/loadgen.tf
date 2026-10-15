locals {
  loadgen_count = var.enable_loadgen ? 1 : 0
}

resource "aws_network_interface" "loadgen" {
  count             = local.loadgen_count
  subnet_id         = aws_subnet.public.id
  security_groups   = [aws_security_group.loadgen.id]
  private_ips_count = var.loadgen_extra_ips
  tags              = { Name = "twelve-dollar-loadgen" }
}

resource "aws_instance" "loadgen" {
  count                = local.loadgen_count
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.loadgen_type
  key_name             = aws_key_pair.operator.key_name
  iam_instance_profile = aws_iam_instance_profile.cwagent.name

  primary_network_interface {
    network_interface_id = aws_network_interface.loadgen[0].id
  }

  # On-demand on purpose: spot r7a.2xlarge was reclaimed mid-session in eu-west-1a, and a reclaim
  # during a hold voids the run. The TTL shutdown in cloud-init terminates the instance.
  instance_initiated_shutdown_behavior = "terminate"

  user_data = templatefile("${path.module}/cloud-init/loadgen.yaml.tftpl", {
    ttl_minutes    = var.loadgen_ttl_minutes
    bench_privkey  = tls_private_key.bench.private_key_openssh
    repo_url       = var.repo_url
    repo_ref       = var.repo_ref
    cwagent_config = local.cwagent_config["loadgen"]
  })
  user_data_replace_on_change = true
  lifecycle {
    ignore_changes = [ami]
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }
  metadata_options {
    http_tokens = "required"
  }
  tags = { Name = "twelve-dollar-loadgen", Role = "loadgen" }
}

resource "aws_eip" "loadgen" {
  count  = local.loadgen_count
  domain = "vpc"
  tags   = { Name = "twelve-dollar-loadgen" }
}

resource "aws_eip_association" "loadgen" {
  count                = local.loadgen_count
  allocation_id        = aws_eip.loadgen[0].id
  network_interface_id = aws_network_interface.loadgen[0].id
}

output "loadgen_enabled" {
  value = var.enable_loadgen
}

output "loadgen_public_ip" {
  value = try(aws_eip.loadgen[0].public_ip, "")
}

output "loadgen_private_ips" {
  value = try(join(",", sort(tolist(aws_network_interface.loadgen[0].private_ips))), "")
}
