# Colony was undeployed on 2026-11-09 after Cicada replaced it.
# Retain SQLite state and namespace snapshot schedules; deleting the data is
# a separate operator decision. Source credentials remain in kv/colony/*.
locals {
  colony_ns = module.namespace["colony"].name

  colony_labels = {
    "app.kubernetes.io/part-of"    = "colony"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
  colonyd_labels = merge(local.colony_labels, {
    "app.kubernetes.io/name"      = "colonyd"
    "app.kubernetes.io/component" = "colonyd"
  })
}

resource "kubernetes_persistent_volume_claim_v1" "colonyd_data" {
  depends_on = [module.namespace["colony"]]

  metadata {
    name      = "colonyd-data"
    namespace = local.colony_ns
    labels    = local.colonyd_labels
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
