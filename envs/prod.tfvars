# Production — REAL RECOMMENDATION commented, lab-safe value active.
# The diff between this file and stg.tfvars is the environment policy, reviewable in a PR.

# prod_sku_name = "GP_Standard_D2ds_v4"   # General Purpose: needed for HA, better IOPS, PgBouncer support
prod_sku_name  = "B_Standard_B1ms"        # lab-safe (cost) — NOT the real recommendation

# prod_retention = 35                      # SOC2-aligned retention window
prod_retention = 7                        # lab-safe

# prod_geo = true                          # geo-redundant backup, set at creation only, cannot be toggled later
prod_geo = false                          # lab-safe
