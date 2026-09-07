resource "azurerm_postgresql_flexible_server" "this" {
  name                          = var.server_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = var.pg_version
  administrator_login           = "pgadmin"
  administrator_password        = var.admin_password
  storage_mb                    = var.storage_mb
  sku_name                      = var.sku_name
  backup_retention_days         = var.backup_retention_days
  geo_redundant_backup_enabled  = var.geo_redundant_backup_enabled
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "myip" {
  name             = "allow-myip"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = var.myip
  end_ip_address   = var.myip
}

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "vector,pgaudit,pg_stat_statements"
}

resource "azurerm_postgresql_flexible_server_configuration" "preload_libraries" {
  name      = "shared_preload_libraries"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "pgaudit,pg_stat_statements"
}

resource "azurerm_postgresql_flexible_server_configuration" "pgaudit_log" {
  name      = "pgaudit.log"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "DDL,ROLE,WRITE"
}

resource "azurerm_postgresql_flexible_server_database" "ciplat" {
  name      = "ciplat"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
