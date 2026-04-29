# =============================================================================
# Perplexica — AI-powered Search
# =============================================================================
# Single container. Runtime config is seeded into the data PVC.
# SearXNG backend: searxng.home.shdr.ch (k8s)
#
# Data migration: tiny volumes (~32KB), can start fresh or copy:
#   perplexica-backend-dbstore-default-perplexica-1vcy9k → memos-data PVC

locals {
  perplexica_image           = "itzcrazykns1337/perplexica:latest"
  perplexica_host            = "perplexica.home.shdr.ch"
  perplexica_port            = 3000
  perplexica_ns              = kubernetes_namespace_v1.personal.metadata[0].name
  perplexica_labels          = { app = "perplexica" }
  perplexica_searxng_url     = "http://searxng.infra.svc.cluster.local:8080"
  perplexica_openai_base_url = "https://litellm.home.shdr.ch/v1"
  perplexica_chat_model_key  = "aether/gemma-4-26b-a4b"
  perplexica_chat_model_name = "Gemma 4 26B A4B (LiteLLM)"
  perplexica_embedding_key   = "aether/qwen3-embedding:4b"
  perplexica_embedding_name  = "Qwen3 Embedding 4B (LiteLLM)"
}

resource "kubernetes_secret_v1" "perplexica_config" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "perplexica-config"
    namespace = local.perplexica_ns
  }

  data = {
    OPENAI_API_KEY = var.secrets["litellm.virtual_keys.perplexica"]
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "perplexica_data" {
  depends_on = [kubernetes_namespace_v1.personal, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "perplexica-data"
    namespace = local.perplexica_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "2Gi" } }
  }
}

resource "kubernetes_deployment_v1" "perplexica" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.perplexica_data,
    kubernetes_secret_v1.perplexica_config,
  ]

  metadata {
    name      = "perplexica"
    namespace = local.perplexica_ns
    labels    = local.perplexica_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = local.perplexica_labels
    }

    template {
      metadata { labels = local.perplexica_labels }

      spec {
        enable_service_links = false

        init_container {
          name  = "configure-perplexica"
          image = local.perplexica_image

          command = ["node", "-e"]
          args = [<<-JS
            const fs = require('fs');
            const crypto = require('crypto');

            const configPath = '/home/perplexica/data/config.json';
            const dataDir = '/home/perplexica/data';
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
            value = local.perplexica_searxng_url
          }
          env {
            name  = "OPENAI_BASE_URL"
            value = local.perplexica_openai_base_url
          }
          env {
            name  = "OPENAI_MODEL"
            value = local.perplexica_chat_model_key
          }
          env {
            name  = "OPENAI_MODEL_NAME"
            value = local.perplexica_chat_model_name
          }
          env {
            name  = "OPENAI_EMBEDDING_MODEL"
            value = local.perplexica_embedding_key
          }
          env {
            name  = "OPENAI_EMBEDDING_MODEL_NAME"
            value = local.perplexica_embedding_name
          }
          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.perplexica_config.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/home/perplexica/data"
          }
        }

        container {
          name  = "perplexica"
          image = local.perplexica_image

          env {
            name  = "SEARXNG_API_URL"
            value = local.perplexica_searxng_url
          }
          env {
            name  = "DATA_DIR"
            value = "/home/perplexica"
          }
          env {
            name  = "OPENAI_BASE_URL"
            value = local.perplexica_openai_base_url
          }
          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.perplexica_config.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }

          port {
            container_port = local.perplexica_port
            name           = "http"
          }

          volume_mount {
            name       = "data"
            mount_path = "/home/perplexica/data"
          }
          volume_mount {
            name       = "uploads"
            mount_path = "/home/perplexica/uploads"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.perplexica_port
            }
            initial_delay_seconds = 15
            period_seconds        = 15
          }
        }

        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.perplexica_data.metadata[0].name }
        }
        volume {
          name = "uploads"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "perplexica" {
  metadata {
    name      = "perplexica"
    namespace = local.perplexica_ns
    labels    = local.perplexica_labels
  }
  spec {
    selector = local.perplexica_labels
    port {
      port        = local.perplexica_port
      target_port = local.perplexica_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "perplexica_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.perplexica]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "perplexica", namespace = local.perplexica_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.perplexica_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "perplexica", port = local.perplexica_port }]
      }]
    }
  }
}
