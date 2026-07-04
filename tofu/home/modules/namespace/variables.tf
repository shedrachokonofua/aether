variable "name" {
  type = string
}

variable "tier" {
  type = string
  validation {
    condition     = contains(["platform", "app", "agent", "sandbox", "guest", "tenant", "unclassified"], var.tier)
    error_message = "Invalid tier."
  }
}

variable "backup" {
  type = string
  validation {
    condition     = contains(["critical", "standard", "none"], var.backup)
    error_message = "Invalid backup."
  }
}

variable "exposure" {
  type = string
  validation {
    condition     = contains(["public", "internal", "tunnel", "lan-vip", "none"], var.exposure)
    error_message = "Invalid exposure."
  }
}

variable "owner" {
  type    = string
  default = "aether"
}

variable "hostnames" {
  type    = list(string)
  default = []
}

variable "description" {
  type    = string
  default = ""
}

variable "source_file" {
  type    = string
  default = ""
}

variable "egress" {
  type    = string
  default = null
}

variable "arch" {
  type    = string
  default = null
}

variable "criticality" {
  type    = string
  default = null
}

variable "ns_lifecycle" {
  type    = string
  default = null
}

variable "registry_access" {
  type    = string
  default = "none"
}

variable "runtime" {
  type    = string
  default = null
}

variable "mesh" {
  type    = string
  default = null
}

variable "extra_labels" {
  type    = map(string)
  default = {}
}

variable "extra_annotations" {
  type    = map(string)
  default = {}
}

variable "create_s3_backup_secret" {
  type    = bool
  default = true
}
