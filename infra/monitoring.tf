# CloudWatch agent on both instances: memory, total CPU, network, disk. EC2's built-in metrics come
# from the hypervisor, cannot see guest memory and are 5-min by default. Metrics land in the
# `twelve-dollar` namespace with a `role` dimension (target|loadgen), so charts survive instance
# replacement. The 5-second sampler on the target (bench/sample-host.sh) stays the source for the report.

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
          net = { # deltas per interval, every interface (dimension `interface`)
            measurement       = ["bytes_recv", "bytes_sent", "packets_recv", "packets_sent"]
            resources         = ["*"]
            append_dimensions = { role = role }
          }
          diskio = { # deltas per interval, every block device (dimension `name`)
            measurement       = ["read_bytes", "write_bytes", "io_time"]
            resources         = ["*"]
            append_dimensions = { role = role }
          }
          disk = {
            measurement       = ["used_percent"]
            resources         = ["/"]
            drop_device       = true
            append_dimensions = { role = role }
          }
        }
      }
    })
  }

  # Widgets: plain metrics where the dimension set is fixed (role only, or role+cpu-total); SEARCH
  # where the agent adds a device dimension we do not want to hardcode (interface, disk name).
  dash_gauge = [
    { title = "CPU % (total)", metric = "cpu_usage_active", extra = ["cpu", "cpu-total"] },
    { title = "Memory used %", metric = "mem_used_percent", extra = [] },
  ]
  dash_search = [
    { title = "Disk used % (/)", schema = "{twelve-dollar,fstype,path,role}", metrics = ["disk_used_percent"], stat = "Maximum", per_s = false },
    { title = "Network bytes/s", schema = "{twelve-dollar,interface,role}", metrics = ["net_bytes_recv", "net_bytes_sent"], stat = "Sum", per_s = true },
    { title = "Network packets/s", schema = "{twelve-dollar,interface,role}", metrics = ["net_packets_recv", "net_packets_sent"], stat = "Sum", per_s = true },
    { title = "Disk I/O bytes/s", schema = "{twelve-dollar,name,role}", metrics = ["diskio_read_bytes", "diskio_write_bytes"], stat = "Sum", per_s = true },
  ]
  dash_widgets = concat(
    [for i, w in local.dash_gauge : {
      type = "metric", x = i * 8, y = 0, width = 8, height = 7
      properties = {
        title = w.title, region = var.region, view = "timeSeries", stat = "Maximum", period = 60
        yAxis = { left = { min = 0, max = 100 } }
        metrics = [for role in ["target", "loadgen"] :
        concat(["twelve-dollar", w.metric, "role", role], w.extra, [{ label = role }])]
      }
    }],
    [for i, w in local.dash_search : {
      type = "metric", x = ((i + 2) % 3) * 8, y = floor((i + 2) / 3) * 7, width = 8, height = 7
      properties = {
        title = w.title, region = var.region, view = "timeSeries", period = 60
        yAxis = { left = { min = 0 } }
        metrics = [for p in setproduct(w.metrics, ["target", "loadgen"]) : [{
          expression = w.per_s ? "SEARCH('${w.schema} MetricName=\"${p[0]}\" role=\"${p[1]}\"', '${w.stat}', 60) / 60" : "SEARCH('${w.schema} MetricName=\"${p[0]}\" role=\"${p[1]}\"', '${w.stat}', 60)"
          label      = "${p[1]} ${replace(replace(p[0], "net_", ""), "diskio_", "")}"
        }]]
      }
    }]
  )
}

resource "aws_cloudwatch_dashboard" "rig" {
  dashboard_name = "twelve-dollar"
  dashboard_body = jsonencode({ widgets = local.dash_widgets })
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.rig.dashboard_name}"
}
