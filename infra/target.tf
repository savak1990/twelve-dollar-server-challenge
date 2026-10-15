resource "aws_instance" "target" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.target_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.target.id]
  key_name               = aws_key_pair.operator.key_name

  user_data = templatefile("${path.module}/cloud-init/target.yaml.tftpl", {
    service_unit = file("${path.module}/systemd/twelve.service")
    sampler_unit = file("${path.module}/systemd/twelve-sampler.service")
    repo_url     = var.repo_url
    repo_ref     = var.repo_ref
    submission   = var.submission
    bench_pubkey = tls_private_key.bench.public_key_openssh
  })
  # Changing REPO_URL/REPO_REF/submission replaces the instance (fresh bootstrap); a newer Canonical
  # AMI must not, or a routine `make test` would destroy a target mid-experiment.
  user_data_replace_on_change = true
  lifecycle {
    ignore_changes = [ami]
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }
  metadata_options {
    http_tokens = "required"
  }
  tags = { Name = "twelve-dollar-target", Role = "target" }
}

output "target_public_ip" {
  value = aws_instance.target.public_ip
}

output "target_private_ip" {
  value = aws_instance.target.private_ip
}

output "repo_url" {
  value = var.repo_url
}

output "repo_ref" {
  value = var.repo_ref
}

output "submission" {
  value = var.submission
}
