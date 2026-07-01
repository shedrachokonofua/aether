# =============================================================================
# SnapOtter — File Processing Toolkit
# =============================================================================
# SQLite-backed single-pod deployment. The current SnapOtter image stores its DB,
# uploaded files, and AI model cache under /data.

locals {
  snapotter_image = "ghcr.io/snapotter-hq/snapotter:latest"
  snapotter_host  = "snapotter.home.shdr.ch"
  snapotter_port  = 1349
  snapotter_ns    = kubernetes_namespace_v1.personal.metadata[0].name
  snapotter_labels = {
    app = "snapotter"
  }
  snapotter_gpu_node_selector = local.gpu_neo_node_selector
  snapotter_ai_bootstrap_labels = {
    app = "snapotter-ai-bootstrap"
    job = "snapotter-ai-bootstrap"
  }
  snapotter_url = "https://${local.snapotter_host}"
  snapotter_ai_bundles = [
    "background-removal",
    "face-detection",
    "object-eraser-colorize",
    "upscale-enhance",
    "photo-restoration",
    "ocr",
  ]
  snapotter_ai_numpy_pin           = "numpy>=2,<2.5"
  snapotter_runtime_config_version = "neo-rembg-gpu-v1"
  snapotter_ai_bootstrap_hash      = substr(sha256(join(",", concat(local.snapotter_ai_bundles, [local.snapotter_ai_numpy_pin, "v5"]))), 0, 12)
}

resource "kubernetes_secret_v1" "snapotter_env" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "snapotter-env"
    namespace = local.snapotter_ns
  }

  type = "Opaque"

  data = {
    AUTH_ENABLED              = "true"
    DEFAULT_USERNAME          = "admin"
    DEFAULT_PASSWORD          = var.secrets["snapotter.admin_password"]
    SKIP_MUST_CHANGE_PASSWORD = "true"
    TRUST_PROXY               = "true"
    EXTERNAL_URL              = local.snapotter_url
    COOKIE_SECRET             = var.secrets["snapotter.cookie_secret"]
    DATA_DIR                  = "/data"
    DB_PATH                   = "/data/snapotter.db"
    FILES_STORAGE_PATH        = "/data/files"
    LOG_DIR                   = "/data/logs"
    WORKSPACE_PATH            = "/tmp/workspace"
    PYTHON_VENV_PATH          = "/data/ai/venv"
    # Neo has enough VRAM for SnapOtter's BiRefNet ONNX CUDA path.
    SNAPOTTER_GPU           = "true"
    MAX_UPLOAD_SIZE_MB      = "2048"
    MAX_BATCH_SIZE          = "100"
    CONCURRENT_JOBS         = "2"
    MAX_WORKER_THREADS      = "4"
    PROCESSING_TIMEOUT_S    = "7200"
    MAX_WORKSPACE_SIZE_GB   = "20"
    MAX_STORAGE_PER_USER_MB = "20000"
    OIDC_ENABLED            = "true"
    OIDC_ISSUER_URL         = var.oidc_issuer_url
    OIDC_CLIENT_ID          = "snapotter"
    OIDC_CLIENT_SECRET      = var.snapotter_oauth_client_secret
    OIDC_SCOPES             = "openid profile email"
    OIDC_PROVIDER_NAME      = "Keycloak"
    OIDC_AUTO_CREATE_USERS  = "true"
    OIDC_AUTO_LINK_USERS    = "true"
    OIDC_DEFAULT_ROLE       = "user"
    ANALYTICS_ENABLED       = "false"
    SENTRY_DSN              = ""
  }
}

resource "kubernetes_persistent_volume_claim_v1" "snapotter_data" {
  depends_on = [kubernetes_namespace_v1.personal, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "snapotter-data"
    namespace = local.snapotter_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "snapotter" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.snapotter_data,
    kubernetes_secret_v1.snapotter_env,
  ]

  metadata {
    name      = "snapotter"
    namespace = local.snapotter_ns
    labels    = local.snapotter_labels
  }

  spec {
    replicas                  = 1
    progress_deadline_seconds = 7200

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.snapotter_labels
    }

    template {
      metadata {
        labels = local.snapotter_labels
        annotations = {
          "aether.shdr.ch/runtime-config" = local.snapotter_runtime_config_version
        }
      }

      spec {
        enable_service_links = false
        runtime_class_name   = "nvidia"
        node_selector        = local.snapotter_gpu_node_selector

        init_container {
          name  = "bootstrap-local-admin"
          image = local.snapotter_image

          command = ["/bin/sh", "-ec", <<-EOT
            set -eu
            python3 - <<'PY'
            import hashlib
            import os
            import secrets
            import sqlite3

            db_path = os.environ.get("DB_PATH", "/data/snapotter.db")
            password = os.environ["DEFAULT_PASSWORD"]

            if not os.path.exists(db_path):
                print(f"{db_path} does not exist yet; app will create the first admin")
                raise SystemExit(0)

            con = sqlite3.connect(db_path)
            try:
                has_users = con.execute(
                    "select 1 from sqlite_master where type = 'table' and name = 'users'"
                ).fetchone()
                if not has_users:
                    print("users table does not exist yet; app migrations will create it")
                    raise SystemExit(0)

                row = con.execute("select id from users where username = ?", ("admin",)).fetchone()
                if not row:
                    print("local admin user does not exist yet")
                    raise SystemExit(0)

                salt_hex = secrets.token_hex(32)
                derived = hashlib.scrypt(
                    password.encode("utf-8"),
                    salt=salt_hex.encode("utf-8"),
                    n=16384,
                    r=8,
                    p=1,
                    dklen=64,
                )
                password_hash = f"{salt_hex}:{derived.hex()}"

                con.execute(
                    """
                    update users
                       set password_hash = ?,
                           role = 'admin',
                           must_change_password = 0,
                           updated_at = unixepoch() * 1000
                     where username = 'admin'
                    """,
                    (password_hash,),
                )
                con.commit()
                print("local admin password synchronized from Kubernetes secret")
            finally:
                con.close()
            PY
          EOT
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.snapotter_env.metadata[0].name
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }

        init_container {
          name  = "bootstrap-ai-gpu-packages"
          image = local.snapotter_image

          command = ["/bin/sh", "-ec", <<-EOT
            set -eu

            marker="/data/ai/gpu-packages-v3"
            legacy_marker="/data/ai/gpu-packages-v1"
            python_bin="/data/ai/venv/bin/python3"
            manifest="/app/docker/feature-manifest.json"
            models_dir="/data/ai/models"

            if [ -f "$marker" ]; then
              echo "SnapOtter AI GPU package bootstrap already completed"
              exit 0
            fi

            if [ ! -x "$python_bin" ]; then
              echo "$python_bin is not present yet; AI bundle installer will create it"
              exit 0
            fi

            nvidia-smi

            if [ ! -f "$legacy_marker" ]; then
              "$python_bin" -m pip uninstall -y \
                torch torchvision torchaudio \
                onnxruntime onnxruntime-gpu \
                paddlepaddle paddlepaddle-gpu || true

              for bundle in ${join(" ", local.snapotter_ai_bundles)}; do
                echo "Installing GPU-capable package set for $bundle"
                "$python_bin" /app/packages/ai/python/install_feature.py \
                  "$bundle" "$manifest" "$models_dir"
              done
            else
              echo "GPU package set is already present; applying compatibility pins"
            fi

            "$python_bin" -m pip install --no-cache-dir "${local.snapotter_ai_numpy_pin}"

            "$python_bin" - <<'PY'
            import sys

            ok = True

            import numpy
            import rembg
            print("numpy", numpy.__version__, "rembg import ok", flush=True)

            import torch
            print(
                "torch",
                torch.__version__,
                "cuda",
                torch.version.cuda,
                "available",
                torch.cuda.is_available(),
                "devices",
                torch.cuda.device_count(),
                flush=True,
            )
            ok = ok and torch.cuda.is_available()

            import onnxruntime as ort
            providers = ort.get_available_providers()
            print("onnxruntime providers", providers, flush=True)
            ok = ok and "CUDAExecutionProvider" in providers

            import paddle
            paddle_cuda = paddle.device.is_compiled_with_cuda()
            print("paddle", paddle.__version__, "cuda_compiled", paddle_cuda, flush=True)
            ok = ok and paddle_cuda

            if not ok:
                raise SystemExit("one or more AI runtimes are still CPU-only")
            PY

            touch "$marker"
          EOT
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.snapotter_env.metadata[0].name
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu              = "500m"
              memory           = "2Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              cpu              = "4"
              memory           = "6Gi"
              "nvidia.com/gpu" = "1"
            }
          }
        }

        container {
          name  = "snapotter"
          image = local.snapotter_image

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.snapotter_env.metadata[0].name
            }
          }

          port {
            container_port = local.snapotter_port
            name           = "http"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/tmp/workspace"
          }

          resources {
            requests = {
              cpu                 = "500m"
              memory              = "4Gi"
              "ephemeral-storage" = "2Gi"
              "nvidia.com/gpu"    = "1"
            }
            limits = {
              cpu                 = "4"
              memory              = "12Gi"
              "ephemeral-storage" = "25Gi"
              "nvidia.com/gpu"    = "1"
            }
          }

          readiness_probe {
            http_get {
              path = "/api/v1/health"
              port = local.snapotter_port
            }
            initial_delay_seconds = 15
            period_seconds        = 15
          }

          liveness_probe {
            http_get {
              path = "/api/v1/health"
              port = local.snapotter_port
            }
            initial_delay_seconds = 90
            period_seconds        = 30
            failure_threshold     = 5
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.snapotter_data.metadata[0].name
          }
        }

        volume {
          name = "workspace"
          empty_dir {
            size_limit = "20Gi"
          }
        }
      }
    }
  }

  timeouts {
    create = "120m"
    update = "120m"
  }
}

resource "kubernetes_job_v1" "snapotter_ai_bootstrap" {
  depends_on = [
    kubernetes_deployment_v1.snapotter,
    kubernetes_service_v1.snapotter,
    kubernetes_secret_v1.snapotter_env,
  ]

  metadata {
    name      = "snapotter-ai-bootstrap-${local.snapotter_ai_bootstrap_hash}"
    namespace = local.snapotter_ns
    labels    = local.snapotter_ai_bootstrap_labels
  }

  spec {
    backoff_limit           = 0
    active_deadline_seconds = 14400

    template {
      metadata {
        labels = local.snapotter_ai_bootstrap_labels
      }

      spec {
        restart_policy       = "Never"
        enable_service_links = false
        node_selector        = local.snapotter_gpu_node_selector

        container {
          name  = "bootstrap"
          image = local.snapotter_image

          command = ["python3", "-c", <<-PY
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

base_url = os.environ["SNAPOTTER_URL"].rstrip("/")
username = os.environ.get("SNAPOTTER_ADMIN_USERNAME", "admin")
password = os.environ["SNAPOTTER_ADMIN_PASSWORD"]
bundles = os.environ["SNAPOTTER_AI_BUNDLES"].split()
python_bin = os.environ.get("SNAPOTTER_AI_PYTHON", "/data/ai/venv/bin/python3")
numpy_pin = os.environ["SNAPOTTER_AI_NUMPY_PIN"]


def request(method, path, payload=None, token=None, timeout=60):
    body = None
    headers = {}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["content-type"] = "application/json"
    if token:
        headers["authorization"] = f"Bearer {token}"
    req = urllib.request.Request(
        base_url + path,
        data=body,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8")
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {"error": raw}
        return err.code, data
    except urllib.error.URLError as err:
        return 0, {"error": str(err)}


for attempt in range(120):
    try:
        code, data = request("GET", "/api/v1/health", timeout=5)
        if code == 200 and data.get("status") == "healthy":
            break
    except Exception:
        pass
    time.sleep(5)
else:
    raise SystemExit("SnapOtter health endpoint did not become ready")

code, data = request(
    "POST",
    "/api/auth/login",
    {"username": username, "password": password},
)
token = data.get("token")
if code != 200 or not token:
    raise SystemExit(f"admin login failed: HTTP {code} {data}")


def bundle_state(bundle_id):
    code, data = request("GET", "/api/v1/features", token=token)
    if code != 200:
        raise RuntimeError(f"feature list failed: HTTP {code} {data}")
    for bundle in data.get("bundles", []):
        if bundle.get("id") == bundle_id:
            return bundle
    raise RuntimeError(f"bundle {bundle_id} missing from feature list")


def wait_installed(bundle_id, timeout_seconds=7200):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        state = bundle_state(bundle_id)
        status = state.get("status")
        progress = state.get("progress") or {}
        print(
            f"{bundle_id}: {status}"
            + (f" {progress.get('percent')}% {progress.get('stage')}" if progress else ""),
            flush=True,
        )
        if status == "installed":
            return
        if status == "error":
            raise RuntimeError(f"{bundle_id} failed: {state.get('error')}")
        time.sleep(30)
    raise TimeoutError(f"{bundle_id} did not install within timeout")


for bundle_id in bundles:
    state = bundle_state(bundle_id)
    status = state.get("status")
    if status == "installed":
        print(f"{bundle_id}: already installed", flush=True)
        continue

    if status != "installing":
        code, data = request(
            "POST",
            f"/api/v1/admin/features/{bundle_id}/install",
            token=token,
        )
        if code == 409 and "already installed" in str(data.get("error", "")):
            print(f"{bundle_id}: already installed", flush=True)
            continue
        if code not in (202, 409):
            raise RuntimeError(f"{bundle_id} install request failed: HTTP {code} {data}")
        print(f"{bundle_id}: install requested", flush=True)

    wait_installed(bundle_id)

print("all requested SnapOtter AI bundles are installed", flush=True)

if os.path.exists(python_bin):
    print(f"pinning AI compatibility package: {numpy_pin}", flush=True)
    subprocess.run(
        [python_bin, "-m", "pip", "install", "--no-cache-dir", numpy_pin],
        check=True,
    )
    subprocess.run(
        [
            python_bin,
            "-c",
            (
                "import numpy, rembg; "
                "print('numpy', numpy.__version__, 'rembg import ok', flush=True)"
            ),
        ],
        check=True,
    )
else:
    print(f"{python_bin} is not present; skipping AI compatibility pin", flush=True)
PY
          ]

          env {
            name  = "SNAPOTTER_URL"
            value = "http://snapotter.${local.snapotter_ns}.svc.cluster.local:${local.snapotter_port}"
          }

          env {
            name  = "SNAPOTTER_ADMIN_USERNAME"
            value = "admin"
          }

          env {
            name = "SNAPOTTER_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.snapotter_env.metadata[0].name
                key  = "DEFAULT_PASSWORD"
              }
            }
          }

          env {
            name  = "SNAPOTTER_AI_BUNDLES"
            value = join(" ", local.snapotter_ai_bundles)
          }

          env {
            name  = "SNAPOTTER_AI_NUMPY_PIN"
            value = local.snapotter_ai_numpy_pin
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "50m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "1Gi" }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.snapotter_data.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "240m"
    update = "240m"
  }
}

resource "kubernetes_service_v1" "snapotter" {
  metadata {
    name      = "snapotter"
    namespace = local.snapotter_ns
    labels    = local.snapotter_labels
  }
  spec {
    selector = local.snapotter_labels
    port {
      port        = local.snapotter_port
      target_port = local.snapotter_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "snapotter_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.snapotter]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "snapotter"
      namespace = local.snapotter_ns
    }
    spec = {
      parentRefs = [
        {
          name      = "main-gateway"
          namespace = "default"
        }
      ]
      hostnames = [local.snapotter_host]
      rules = [
        {
          backendRefs = [
            {
              name = "snapotter"
              port = local.snapotter_port
            }
          ]
        }
      ]
    }
  }
}
