# =============================================================================
# SABnzbd — Usenet downloader
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Config restored from VM export tarball into the ceph-rbd PVC after first apply.
# Downloads share the existing media-hdd NFS PVC (jellyfin) at sub_path "downloads".

locals {
  sabnzbd_image         = "lscr.io/linuxserver/sabnzbd:latest"
  sabnzbd_host          = "sabnzbd.home.shdr.ch"
  sabnzbd_port          = 8080
  sabnzbd_ns            = local.media_ns
  sabnzbd_labels        = { app = "sabnzbd" }
  sabnzbd_username      = "aether"
  sabnzbd_auth_revision = nonsensitive(substr(sha256(join(":", [local.sabnzbd_username, var.secrets["sabnzbd.password"], var.secrets["sabnzbd.api_key"]])), 0, 16))
}

# =============================================================================
# Config PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "sabnzbd_config" {
  depends_on = [module.namespace["media"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "sabnzbd-config"
    namespace = local.sabnzbd_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "5Gi" }
    }
  }
}

# SABnzbd has no supported username/password environment variables. Reconcile
# only its native security keys in the PVC-backed ConfigObj file before startup.
resource "kubernetes_secret_v1" "sabnzbd_auth" {
  depends_on = [module.namespace["media"]]

  metadata {
    name      = "sabnzbd-auth"
    namespace = local.sabnzbd_ns
  }

  type = "Opaque"

  data = {
    username = local.sabnzbd_username
    password = var.secrets["sabnzbd.password"]
    api_key  = var.secrets["sabnzbd.api_key"]
  }
}

resource "kubernetes_secret_v1" "sabnzbd_client_reconcile" {
  depends_on = [module.namespace["media"]]

  metadata {
    name      = "sabnzbd-client-reconcile"
    namespace = local.sabnzbd_ns
  }

  type = "Opaque"

  data = {
    sabnzbd_api_key = var.secrets["sabnzbd.api_key"]
    sonarr_api_key  = var.secrets["sonarr.api_key"]
    radarr_api_key  = var.secrets["radarr.api_key"]
    lidarr_api_key  = var.secrets["lidarr.api_key"]
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "sabnzbd" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.sabnzbd_config,
    kubernetes_persistent_volume_claim_v1.media_hdd,
    kubernetes_secret_v1.sabnzbd_auth,
  ]

  metadata {
    name      = "sabnzbd"
    namespace = local.sabnzbd_ns
    labels    = local.sabnzbd_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.sabnzbd_labels
    }

    template {
      metadata {
        labels = local.sabnzbd_labels
        annotations = {
          "aether.shdr.ch/sabnzbd-auth-sha" = local.sabnzbd_auth_revision
        }
      }

      spec {
        init_container {
          name  = "reconcile-native-auth"
          image = local.sabnzbd_image

          command = ["python3", "-c", <<-PY
import os
import tempfile
from pathlib import Path

from configobj import ConfigObj

config_path = Path("/config/sabnzbd.ini")
secret_dir = Path("/run/secrets/sabnzbd-auth")
staging_root = Path("/downloads/mingus")
desired = {
    "username": (secret_dir / "username").read_text(encoding="utf-8").strip(),
    "password": (secret_dir / "password").read_text(encoding="utf-8").strip(),
    "api_key": (secret_dir / "api_key").read_text(encoding="utf-8").strip(),
    "html_login": "1",
    "inet_exposure": "0",
}
desired_category = {
    "name": "mingus",
    "order": "5",
    "pp": "3",
    "script": "None",
    "dir": "mingus",
    "newzbin": "",
    "priority": "0",
}

if not config_path.is_file():
    raise SystemExit(f"{config_path} is missing; refusing to replace the restored configuration")
if not all(desired.values()):
    raise SystemExit("SABnzbd native-auth inputs must be non-empty")
staging_root.mkdir(parents=True, exist_ok=True)
os.chmod(staging_root, 0o777)

original_stat = config_path.stat()
config = ConfigObj(str(config_path), encoding="utf-8", interpolation=False)
misc = config.setdefault("misc", {})
category = config.setdefault("categories", {}).setdefault("mingus", {})
changed = (
    any(str(misc.get(key, "")) != value for key, value in desired.items())
    or any(str(category.get(key, "")) != value for key, value in desired_category.items())
)

if changed:
    for key, value in desired.items():
        misc[key] = value
    for key, value in desired_category.items():
        category[key] = value
    fd, temporary_name = tempfile.mkstemp(prefix=".sabnzbd.ini.", dir=config_path.parent)
    os.close(fd)
    try:
        config.filename = temporary_name
        config.write()
        os.chown(temporary_name, original_stat.st_uid, original_stat.st_gid)
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, config_path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
else:
    os.chmod(config_path, 0o600)

print("SABnzbd native authentication and Mingus category reconciled")
PY
          ]

          security_context {
            run_as_non_root            = true
            run_as_user                = 1000
            run_as_group               = 1000
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "auth"
            mount_path = "/run/secrets/sabnzbd-auth"
            read_only  = true
          }

          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }

        container {
          name  = "sabnzbd"
          image = local.sabnzbd_image

          port {
            container_port = local.sabnzbd_port
            name           = "http"
          }

          env {
            name  = "PUID"
            value = "1000"
          }

          env {
            name  = "PGID"
            value = "1000"
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          env {
            name  = "HOST_WHITELIST_ENTRIES"
            value = local.sabnzbd_host
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
            sub_path   = "downloads"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "4"
              memory = "4Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = local.sabnzbd_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = local.sabnzbd_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.sabnzbd_config.metadata[0].name
          }
        }

        volume {
          name = "auth"
          secret {
            secret_name  = kubernetes_secret_v1.sabnzbd_auth.metadata[0].name
            default_mode = "0444"
          }
        }

        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.media_hdd.metadata[0].name
          }
        }
      }
    }
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "sabnzbd" {
  metadata {
    name      = "sabnzbd"
    namespace = local.sabnzbd_ns
    labels    = local.sabnzbd_labels
  }

  spec {
    selector = local.sabnzbd_labels

    port {
      port        = local.sabnzbd_port
      target_port = local.sabnzbd_port
      name        = "http"
    }
  }
}

# Stateful *arr configuration is PVC-owned rather than Terraform-owned. Reconcile
# its SABnzbd download-client credential after native auth/API-key rotation and
# keep machine traffic on the in-namespace Service instead of the ingress route.
resource "kubernetes_job_v1" "sabnzbd_client_reconcile" {
  depends_on = [
    kubernetes_deployment_v1.sabnzbd,
    kubernetes_service_v1.sabnzbd,
    kubernetes_secret_v1.sabnzbd_client_reconcile,
  ]

  metadata {
    name      = "sabnzbd-client-reconcile"
    namespace = local.sabnzbd_ns
    labels    = merge(local.sabnzbd_labels, { job = "sabnzbd-client-reconcile" })
  }

  spec {
    backoff_limit           = 3
    active_deadline_seconds = 600

    template {
      metadata {
        labels = merge(local.sabnzbd_labels, { job = "sabnzbd-client-reconcile" })
        annotations = {
          "aether.shdr.ch/sabnzbd-auth-sha" = local.sabnzbd_auth_revision
        }
      }

      spec {
        restart_policy       = "OnFailure"
        enable_service_links = false

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "reconcile"
          image = local.sabnzbd_image

          command = ["python3", "-c", <<-PY
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

secret_dir = Path("/run/secrets/sabnzbd-client-reconcile")


def secret(name):
    value = (secret_dir / name).read_text(encoding="utf-8").strip()
    if not value:
        raise RuntimeError(f"secret {name} is empty")
    return value


def request_json(method, url, api_key=None, payload=None, timeout=15):
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"accept": "application/json"}
    if payload is not None:
        headers["content-type"] = "application/json"
    if api_key:
        headers["x-api-key"] = api_key
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def wait_for(description, operation, attempts=60):
    last_error = None
    for _ in range(attempts):
        try:
            return operation()
        except (OSError, ValueError, urllib.error.URLError) as error:
            last_error = error
            time.sleep(5)
    raise RuntimeError(f"{description} did not become ready: {last_error}")


sabnzbd_key = secret("sabnzbd_api_key")
sabnzbd_query = urllib.parse.urlencode(
    {"mode": "queue", "output": "json", "apikey": sabnzbd_key}
)
wait_for(
    "SABnzbd API",
    lambda: request_json("GET", f"http://sabnzbd:${local.sabnzbd_port}/api?{sabnzbd_query}"),
)

applications = [
    ("Sonarr", "http://sonarr:${local.sonarr_port}/api/v3", secret("sonarr_api_key")),
    ("Radarr", "http://radarr:${local.radarr_port}/api/v3", secret("radarr_api_key")),
    ("Lidarr", "http://lidarr:${local.lidarr_port}/api/v1", secret("lidarr_api_key")),
]

for name, base_url, application_key in applications:
    clients = wait_for(
        f"{name} API",
        lambda base_url=base_url, application_key=application_key: request_json(
            "GET", f"{base_url}/downloadclient", application_key
        ),
    )
    sabnzbd_clients = [client for client in clients if client.get("implementation") == "Sabnzbd"]
    if len(sabnzbd_clients) != 1:
        raise RuntimeError(f"{name} must have exactly one SABnzbd download client")

    client = sabnzbd_clients[0]
    fields = {field["name"]: field for field in client.get("fields", [])}
    desired = {
        "host": "sabnzbd",
        "port": ${local.sabnzbd_port},
        "useSsl": False,
        "apiKey": sabnzbd_key,
    }
    missing = sorted(set(desired) - set(fields))
    if missing:
        raise RuntimeError(f"{name} SABnzbd client is missing fields: {missing}")
    for field_name, value in desired.items():
        fields[field_name]["value"] = value

    request_json("POST", f"{base_url}/downloadclient/test", application_key, client)
    request_json(
        "PUT",
        f"{base_url}/downloadclient/{client['id']}",
        application_key,
        client,
    )
    print(f"{name} SABnzbd client reconciled")
PY
          ]

          volume_mount {
            name       = "client-credentials"
            mount_path = "/run/secrets/sabnzbd-client-reconcile"
            read_only  = true
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "client-credentials"
          secret {
            secret_name  = kubernetes_secret_v1.sabnzbd_client_reconcile.metadata[0].name
            default_mode = "0444"
          }
        }
      }
    }

    completions = 1
  }

  wait_for_completion = true

  timeouts {
    create = "15m"
    update = "15m"
  }

  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "sabnzbd_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.sabnzbd]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "sabnzbd"
      namespace = local.sabnzbd_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.sabnzbd_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" }
            ]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.sabnzbd.metadata[0].name
          port = local.sabnzbd_port
        }]
      }]
    }
  }
}
