variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "az" {
  type    = string
  default = "eu-west-1a"
}

variable "ssh_pubkey_path" {
  type        = string
  description = "Public key installed on both instances (ubuntu user)."
}

variable "my_ip" {
  type        = string
  description = "Operator IPv4; the only source allowed on port 22."
}

variable "target_type" {
  type    = string
  default = "c7a.medium" # 1 vCPU / 2 GiB, not burstable
}

variable "submission" {
  type        = string
  default     = "go-fasthttp-savak1990"
  description = "Folder under submissions/ to run on the target."
}

variable "repo_url" {
  type        = string
  default     = "https://github.com/savak1990/twelve-dollar-server-challenge.git"
  description = "Public git URL of this repo. Both instances clone it at boot; nothing is copied from the workstation."
  validation {
    condition     = can(regex("^https://", var.repo_url))
    error_message = "repo_url must be a public https:// git URL (cloud-init has no credentials)."
  }
}

variable "repo_ref" {
  type    = string
  default = "main"
}

variable "enable_loadgen" {
  type    = bool
  default = false
}

variable "loadgen_type" {
  type    = string
  default = "r7a.2xlarge" # 8 vCPU / 64 GiB; k6 needs ~280 KB per VU
}

variable "loadgen_spot" {
  type    = bool
  default = true
}

variable "loadgen_extra_ips" {
  type        = number
  default     = 3
  description = "Secondary private IPs on the loadgen ENI (k6 --local-ips) to multiply the ephemeral port space."
}

variable "loadgen_ttl_minutes" {
  type        = number
  default     = 360
  description = "The loadgen shuts itself down after this long, as a cost fuse."
}
