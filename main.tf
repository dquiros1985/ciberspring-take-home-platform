terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    vercel = {
      source  = "vercel/vercel"
      version = ">= 4.8"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "vercel" {
  # api_token read from VERCEL_API_TOKEN env var — see vault-project-env.sh
}

variable "myip" {
  type    = string
  default = "<REDACTED_HOME_IP>"
}

variable "location" {
  type    = string
  default = "centralus"
}

# --- staging ---
variable "stg_admin_password" {
  type      = string
  sensitive = true
}

variable "stg_sku_name" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "stg_retention" {
  type    = number
  default = 7
}

variable "stg_geo" {
  type    = bool
  default = false
}

resource "azurerm_resource_group" "stg" {
  name     = "rg-ciplat-stg"
  location = var.location
  tags     = { env = "stg", project = "ciplat", owner = "david" }
}

module "pg_stg" {
  source                       = "./modules/pg-env"
  location                     = azurerm_resource_group.stg.location
  resource_group_name          = azurerm_resource_group.stg.name
  server_name                  = "pg-ciplat-stg-0a99"
  admin_password               = var.stg_admin_password
  myip                         = var.myip
  sku_name                     = var.stg_sku_name
  backup_retention_days        = var.stg_retention
  geo_redundant_backup_enabled = var.stg_geo
  tags                         = { env = "stg", project = "ciplat", owner = "david" }
}

# --- production ---
# NOTE: real recommended values are commented next to each active (lab-safe) default below.
# The DIFF between stg and prod values is itself the environment policy, reviewable in a PR.
variable "prod_admin_password" {
  type      = string
  sensitive = true
}

variable "prod_sku_name" {
  type    = string
  default = "B_Standard_B1ms" # real recommendation: GP_Standard_D2ds_v4
}

variable "prod_retention" {
  type    = number
  default = 7 # real recommendation: 35
}

variable "prod_geo" {
  type    = bool
  default = false # real recommendation: true
}

resource "azurerm_resource_group" "prod" {
  name     = "rg-ciplat-prod"
  location = var.location
  tags     = { env = "prod", project = "ciplat", owner = "david" }
}

module "pg_prod" {
  source                       = "./modules/pg-env"
  location                     = azurerm_resource_group.prod.location
  resource_group_name          = azurerm_resource_group.prod.name
  server_name                  = "pg-ciplat-prod-0a99"
  admin_password               = var.prod_admin_password
  myip                         = var.myip
  sku_name                     = var.prod_sku_name
  backup_retention_days        = var.prod_retention
  geo_redundant_backup_enabled = var.prod_geo
  tags                         = { env = "prod", project = "ciplat", owner = "david" }
}

output "stg_fqdn" {
  value = module.pg_stg.fqdn
}

output "prod_fqdn" {
  value = module.pg_prod.fqdn
}
