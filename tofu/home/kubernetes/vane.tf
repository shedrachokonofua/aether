# =============================================================================
# Vane — AI-powered Search
# =============================================================================
# Single container. Runtime config is seeded into the data PVC.
# SearXNG backend: searxng.home.shdr.ch (k8s)
# Uses slim image since we run our own SearXNG instance.
#
# Formerly Perplexica (rebranded upstream, same author).

locals {
  vane_image           = "itzcrazykns1337/vane:slim-latest"
  vane_host            = "vane.home.shdr.ch"
  vane_port            = 3000
  vane_ns              = module.namespace["personal"].name
  vane_labels          = { app = "vane" }
  vane_searxng_url     = "http://searxng.infra.svc.cluster.local:8080"
  vane_openai_base_url = "https://litellm.home.shdr.ch/v1"
  vane_chat_model_key  = "aether/gemma-4-26b-a4b"
  vane_chat_model_name = "Gemma 4 26B A4B (LiteLLM)"
  vane_embedding_key   = "aether/qwen3-embedding:4b"
  vane_embedding_name  = "Qwen3 Embedding 4B (LiteLLM)"
}

resource "kubernetes_secret_v1" "vane_config" {
  depends_on = [module.namespace["personal"]]

  metadata {
    name      = "vane-config"
    namespace = local.vane_ns
  }

  data = {
    OPENAI_API_KEY = var.secrets["litellm.virtual_keys.perplexica"]
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "vane_data" {
  depends_on = [module.namespace["personal"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "vane-data"
    namespace = local.vane_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "2Gi" } }
  }
}

resource "kubernetes_deployment_v1" "vane" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.vane_data,
    kubernetes_secret_v1.vane_config,
  ]

  metadata {
    name      = "vane"
    namespace = local.vane_ns
    labels    = local.vane_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = local.vane_labels
    }

    template {
      metadata { labels = local.vane_labels }

      spec {
        enable_service_links = false

        init_container {
          name  = "configure-vane"
          image = local.vane_image

          command = ["node", "-e"]
          args = [<<-JS
            const fs = require('fs');
            const crypto = require('crypto');

            const configPath = '/home/vane/data/config.json';
            const dataDir = '/home/vane/data';
            fs.mkdirSync(dataDir, { recursive: true });

            let config = {
              version: 1,
              setupComplete: true,
              preferences: {},
              personalization: {},
              modelProviders: [],
              search: {},
            };

            if (fs.existsSync(configPath)) {
              config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
            }

            config.version ??= 1;
            config.preferences ??= {};
            config.personalization ??= {};
            config.modelProviders ??= [];
            config.search ??= {};
            config.setupComplete = true;
            config.search.searxngURL = process.env.SEARXNG_API_URL;

            const providerConfig = {
              apiKey: process.env.OPENAI_API_KEY,
              baseURL: process.env.OPENAI_BASE_URL,
            };

            if (!providerConfig.apiKey || !providerConfig.baseURL) {
              throw new Error('OPENAI_API_KEY and OPENAI_BASE_URL are required');
            }

            const providerHash = crypto
              .createHash('sha256')
              .update(JSON.stringify(providerConfig, Object.keys(providerConfig).sort()))
              .digest('hex');

            const model = {
              name: process.env.OPENAI_MODEL_NAME,
              key: process.env.OPENAI_MODEL,
            };
            const embeddingModel = {
              name: process.env.OPENAI_EMBEDDING_MODEL_NAME,
              key: process.env.OPENAI_EMBEDDING_MODEL,
            };

            const provider = {
              id: 'litellm',
              name: 'LiteLLM',
              type: 'openai',
              config: providerConfig,
              hash: providerHash,
              chatModels: [model],
              embeddingModels: [embeddingModel],
            };

            const existingIndex = config.modelProviders.findIndex((p) =>
              p.id === provider.id ||
              p.hash === provider.hash ||
              (p.type === 'openai' && p.config?.baseURL === provider.config.baseURL)
            );

            if (existingIndex >= 0) {
              const existing = config.modelProviders[existingIndex];
              const chatModels = [
                ...((existing.chatModels || []).filter((m) => m.key !== model.key)),
                model,
              ];
              const embeddingModels = [
                ...((existing.embeddingModels || []).filter((m) => m.key !== embeddingModel.key)),
                embeddingModel,
              ];

              config.modelProviders[existingIndex] = {
                ...existing,
                ...provider,
                chatModels,
                embeddingModels,
              };
            } else {
              config.modelProviders.push(provider);
            }

            fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
          JS
          ]

          env {
            name  = "SEARXNG_API_URL"
            value = local.vane_searxng_url
          }
          env {
            name  = "OPENAI_BASE_URL"
            value = local.vane_openai_base_url
          }
          env {
            name  = "OPENAI_MODEL"
            value = local.vane_chat_model_key
          }
          env {
            name  = "OPENAI_MODEL_NAME"
            value = local.vane_chat_model_name
          }
          env {
            name  = "OPENAI_EMBEDDING_MODEL"
            value = local.vane_embedding_key
          }
          env {
            name  = "OPENAI_EMBEDDING_MODEL_NAME"
            value = local.vane_embedding_name
          }
          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.vane_config.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/home/vane/data"
          }
        }

        container {
          name  = "vane"
          image = local.vane_image

          env {
            name  = "SEARXNG_API_URL"
            value = local.vane_searxng_url
          }
          env {
            name  = "DATA_DIR"
            value = "/home/vane"
          }
          env {
            name  = "OPENAI_BASE_URL"
            value = local.vane_openai_base_url
          }
          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.vane_config.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }

          port {
            container_port = local.vane_port
            name           = "http"
          }

          volume_mount {
            name       = "data"
            mount_path = "/home/vane/data"
          }
          volume_mount {
            name       = "uploads"
            mount_path = "/home/vane/uploads"
          }

          resources {
            requests = { cpu = "100m", memory = "512Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.vane_port
            }
            initial_delay_seconds = 15
            period_seconds        = 15
          }
        }

        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.vane_data.metadata[0].name }
        }
        volume {
          name = "uploads"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "vane" {
  metadata {
    name      = "vane"
    namespace = local.vane_ns
    labels    = local.vane_labels
  }
  spec {
    selector = local.vane_labels
    port {
      port        = local.vane_port
      target_port = local.vane_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "vane_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.vane]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "vane", namespace = local.vane_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.vane_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "vane", port = local.vane_port }]
      }]
    }
  }
}
