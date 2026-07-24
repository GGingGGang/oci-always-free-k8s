variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "fingerprint" {
  type = string
}

variable "private_key_path" {
  type = string
}

variable "region" {
  type = string
}

variable "compartment_ocid" {
  type = string
}

variable "ssh_authorized_keys" {
  type = string
}

variable "db_admin_password" {
  type      = string
  sensitive = true
}

variable "kubernetes_version" {
  type    = string
  default = "v1.34.2"
}

variable "allowed_cidr" {
  type        = string
  description = "공인 서비스 접근 허용 IP (e.g. 1.2.3.4/32)"
}

variable "object_storage_buckets" {
  type        = list(string)
  description = "Object Storage 버킷 목록 (OpenBao raft snapshot, Loki chunks 등)"
  default     = ["bao-snapshots"]
}
