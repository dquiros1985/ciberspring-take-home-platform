variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "server_name" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "sku_name" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "storage_mb" {
  type    = number
  default = 32768
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "geo_redundant_backup_enabled" {
  type    = bool
  default = false
}

variable "pg_version" {
  type    = string
  default = "16"
}

variable "myip" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
