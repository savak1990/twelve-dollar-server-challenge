# CloudWatch agent on both instances: memory and total CPU. EC2's built-in metrics come from the
# hypervisor, cannot see guest memory and are 5-min by default. Metrics land in the `twelve-dollar`
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
          cpu = {
            measurement       = ["usage_active"]
            totalcpu          = true
            append_dimensions = { role = role }
          }
        }
      }
    })
  }
}

resource "aws_cloudwatch_dashboard" "rig" {
  dashboard_name = "twelve-dollar"
  dashboard_body = jsonencode({
    widgets = [
      for i, w in [
        { title = "CPU % (total)", metric = "cpu_usage_active", extra = ["cpu", "cpu-total"] },
        { title = "Memory used %", metric = "mem_used_percent", extra = [] },
        ] : {
        type   = "metric"
        x      = i * 12
        y      = 0
        width  = 12
        height = 8
        properties = {
          title  = w.title
          region = var.region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          yAxis  = { left = { min = 0, max = 100 } }
          metrics = [
            for role in ["target", "loadgen"] :
            concat(["twelve-dollar", w.metric, "role", role], w.extra, [{ label = role }])
          ]
        }
      }
    ]
  })
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.rig.dashboard_name}"
}
