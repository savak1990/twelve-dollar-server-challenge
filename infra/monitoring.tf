# CloudWatch agent on both instances, memory only. EC2's built-in metrics come from the hypervisor
# and cannot see guest memory; the agent pushes it from inside. Metrics land in the `twelve-dollar`
# namespace with a `role` dimension (target|loadgen), so charts survive instance replacement.
# The 5-second sampler on the target (bench/sample-host.sh) stays the source for the report.

resource "aws_iam_role" "cwagent" {
  name = "twelve-dollar-cwagent"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cwagent" {
  role       = aws_iam_role.cwagent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "cwagent" {
  name = "twelve-dollar-cwagent"
  role = aws_iam_role.cwagent.name
}

locals {
  cwagent_config = {
    for role in ["target", "loadgen"] : role => jsonencode({
      agent = {
        metrics_collection_interval = var.cwagent_interval_seconds
        omit_hostname               = true
      }
      metrics = {
        namespace = "twelve-dollar"
        metrics_collected = {
          mem = {
            measurement       = ["mem_used_percent", "mem_used", "mem_available"]
            append_dimensions = { role = role }
          }
        }
      }
    })
  }
}
