# =============================================================================
# llama-swap — LLM Model Serving
# =============================================================================
# Manages llama-server processes with on-demand model loading/unloading.
# Replaces Ollama + vLLM on the GPU Workstation.
#
# Architecture: llama-swap (Go proxy) spawns llama-server child processes
# per model request, with TTL-based unloading to free VRAM.

locals {
  # b10423+ for Muse Glimmer (ggml-org/llama.cpp#26841).
  llama_swap_image   = "ghcr.io/mostlygeek/llama-swap:v250-cuda-b10423"
  llama_swap_host    = "llama-swap.home.shdr.ch"
  llama_swap_port    = 8080
  llama_swap_ns      = module.namespace["ai-serving"].name
  llama_swap_subpath = "llama-swap/models"
  # audio.cpp provides audiocpp_server for the speech models below; the
  # install-audiocpp init container copies its /app onto the PV. Digest of
  # ghcr tag full-cuda12-20260814-04ba437.
  audiocpp_image_tag = "full-cuda12-20260814-04ba437"
  audiocpp_image     = "ghcr.io/0xshug0/audio.cpp@sha256:73355831b1a31bc417778c7ff922bd80dd12f5ae07b8e9cbbd800a66a3290ea8"
  llama_swap_labels  = { app = "llama-swap" }
}

# =============================================================================
# ConfigMap — llama-swap config
# =============================================================================

resource "kubernetes_config_map_v1" "llama_swap_config" {
  metadata {
    name      = "llama-swap-config"
    namespace = local.llama_swap_ns
  }

  data = {
    "config.yaml" = <<-YAML
      healthCheckTimeout: 900
      logLevel: info
      logToStdout: both
      globalTTL: 300

      # Warm the pinned pair at boot; both are members of the llm matrix set
      # (chat & emb), so they co-reside instead of swapping each other out.
      hooks:
        on_startup:
          preload:
            - "qwen3.8-27b"
            - "qwen3-embedding-0.6b"

      models:
        "qwen3.8-27b":
          # MTP (multi-token prediction) speculative decoding: ~1.4-2.2x faster
          # generation, same accuracy. 3.8 ships MTP weights in the main GGUF
          # (no separate -MTP-GGUF variant as with 3.6).
          # https://unsloth.ai/docs/models/qwen3.8
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/Qwen3.8-27B-GGUF:Q8_0
            -ngl 99
            --no-mmap
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 262144
            --spec-type draft-mtp
            --spec-draft-n-max 2
          # Pinned (ttl 0 = never unload): the hourly briefing agent was
          # cycling this model 24x/day (load -> 15min TTL -> unload), so every
          # interactive call (Beryl, AFFiNE, Orion) paid the ~11s cold load.
          # 96GB Blackwell, 3-day peak usage 63GB - pinning fits comfortably.
          ttl: 0
          filters:
            setParamsByID:
              "qwen3.8-27b":
                chat_template_kwargs:
                  enable_thinking: false
                temperature: 0.7
                top_p: 0.8
                top_k: 20
                min_p: 0.0
                presence_penalty: 1.5
              "qwen3.8-27b:code":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 0.6
                top_p: 0.95
                top_k: 20
                min_p: 0.0
                presence_penalty: 0.0
              "qwen3.8-27b:think":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 1.0
                top_p: 0.95
                top_k: 20
                min_p: 0.0
                presence_penalty: 1.5

        "qwen3.6-35b-a3b":
          # MTP speculative decoding — see qwen3.8-27b above.
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q8_0
            -ngl 99
            --no-mmap
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 262144
            --spec-type draft-mtp
            --spec-draft-n-max 2
          ttl: 900
          filters:
            setParamsByID:
              "qwen3.6-35b-a3b":
                chat_template_kwargs:
                  enable_thinking: false
                temperature: 0.7
                top_p: 0.8
                top_k: 20
                min_p: 0.0
                presence_penalty: 1.5
              "qwen3.6-35b-a3b:code":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 0.6
                top_p: 0.95
                top_k: 20
                min_p: 0.0
                presence_penalty: 0.0
              "qwen3.6-35b-a3b:think":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 1.0
                top_p: 0.95
                top_k: 20
                min_p: 0.0
                presence_penalty: 1.5

        "qwen3.5-9b":
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/Qwen3.5-9B-GGUF:Q8_0
            -ngl 99
            --no-mmap
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 131072
          ttl: 900
          filters:
            setParamsByID:
              "qwen3.5-9b":
                chat_template_kwargs:
                  enable_thinking: false
                temperature: 0.7
                top_p: 0.8
                top_k: 20
                min_p: 0.0
                presence_penalty: 1.5
              "qwen3.5-9b:think":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 1.0
                top_p: 0.95
                top_k: 20
                min_p: 0.0
                presence_penalty: 1.5

        "bge-reranker-v2-m3":
          cmd: >
            llama-server
            --port $${PORT}
            -hf pyarn/bge-reranker-v2-m3-Q8_0-GGUF
            -ngl 99
            --reranking
          ttl: 120

        # Qwen3-Reranker: unlike bge-v2-m3 it handles inferential relevance
        # ("fell off Dr. Rehal's roster" ⇒ "my family doctor") instead of
        # lexical overlap only — the ceiling mnemo RAG hit on 2026-07-09.
        # Voodisss conversion is the verified one (official
        # convert_hf_to_gguf.py: cls.output.weight + pooling_type=RANK;
        # most community GGUFs are broken, near-zero scores). Q4_K_M is
        # within 1% of F16 on MTEB rerank per the repo's benchmark.
        "qwen3-reranker-4b":
          cmd: >
            llama-server
            --port $${PORT}
            -hf Voodisss/Qwen3-Reranker-4B-GGUF-llama_cpp
            -hff Qwen3-Reranker-4B-Q4_K_M.gguf
            -ngl 99
            --reranking
            --pooling rank
            --embedding
          ttl: 120

        "gemma-4-31b":
          # MTP speculative decoding: ~1.4x+ faster generation, same accuracy.
          # MTP draft GGUFs live in the same HF repo; the gemma4-assistant
          # draft arch needs llama.cpp post-2026-06-08 (b9571+).
          # ~2 GB extra VRAM vs non-MTP.
          # `-hff` pins the main GGUF: the repo's latest revision makes the
          # :Q8_0 tag resolve to the MTP draft, which then fails to load as
          # the main model (ctx_other error — ggml-org/llama.cpp#24443).
          # `-fit off`: auto memory-fitting can't measure the gemma4-assistant
          # draft context and aborts the load — ggml-org/llama.cpp#24343.
          # https://unsloth.ai/docs/models/mtp#gemma-4-mtp
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/gemma-4-31B-it-GGUF:Q8_0
            -hff gemma-4-31B-it-Q8_0.gguf
            -ngl 99
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 262144
            --spec-type draft-mtp
            --spec-draft-n-max 2
            -fit off
          ttl: 900
          filters:
            setParamsByID:
              "gemma-4-31b":
                chat_template_kwargs:
                  enable_thinking: false
                temperature: 1.0
                top_p: 0.95
                top_k: 64
              "gemma-4-31b:think":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 1.0
                top_p: 0.95
                top_k: 64

        "gemma-4-26b-a4b":
          # MTP speculative decoding (+ -hff, -fit off) — see gemma-4-31b above.
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/gemma-4-26B-A4B-it-GGUF:Q8_0
            -hff gemma-4-26B-A4B-it-Q8_0.gguf
            -ngl 99
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 262144
            --spec-type draft-mtp
            --spec-draft-n-max 2
            -fit off
          ttl: 900
          filters:
            setParamsByID:
              "gemma-4-26b-a4b":
                chat_template_kwargs:
                  enable_thinking: false
                temperature: 1.0
                top_p: 0.95
                top_k: 64
              "gemma-4-26b-a4b:think":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 1.0
                top_p: 0.95
                top_k: 64

        "muse-glimmer-30b":
          # Thinking via reasoning_effort (low/medium/high/xhigh), not
          # enable_thinking. Params are Meta's defaults.
          # https://unsloth.ai/docs/models/muse-glimmer
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/Muse-Glimmer-30B-GGUF:Q8_0
            -ngl 99
            --no-mmap
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 131072
          ttl: 900
          filters:
            setParamsByID:
              "muse-glimmer-30b":
                temperature: 1.0
                top_p: 0.95
                top_k: 64
              "muse-glimmer-30b:think":
                chat_template_kwargs:
                  reasoning_effort: high
                temperature: 1.0
                top_p: 0.95
                top_k: 64

        "qwen3-embedding-4b":
          cmd: >
            llama-server
            --port $${PORT}
            -hf Qwen/Qwen3-Embedding-4B-GGUF:Q8_0
            -ngl 99
            --embedding
            --pooling last
          ttl: 120

        "qwen3-embedding-0.6b":
          cmd: >
            llama-server
            --port $${PORT}
            -hf Qwen/Qwen3-Embedding-0.6B-GGUF:Q8_0
            -ngl 99
            --embedding
            --pooling last
          # Pinned alongside the chat model (~1GB): kills the measured 3.4s
          # cold-swap on AFFiNE/mnemo/Vane embedding calls.
          ttl: 0

        # Speech via audio.cpp (binaries on the PV, see install-audiocpp).
        # audiocpp_server serves /v1/audio/speech + /v1/audio/transcriptions
        # and takes --port, so llama-swap manages it like any llama-server.
        # Must run FROM the bin dir: the server resolves model_specs/ against
        # CWD (the model_spec_override config key does not take effect).
        "qwen3-asr-0.6b":
          cmd: >
            sh -c "cd /models/audiocpp/bin && exec env LD_LIBRARY_PATH=.
            ./audiocpp_server --config /config/audiocpp-asr.json
            --host 127.0.0.1 --port $${PORT}"
          ttl: 600

        "qwen3-tts-0.6b":
          cmd: >
            sh -c "cd /models/audiocpp/bin && exec env LD_LIBRARY_PATH=.
            ./audiocpp_server --config /config/audiocpp-tts.json
            --host 127.0.0.1 --port $${PORT}"
          ttl: 600

      matrix:
        vars:
          q3827: "qwen3.8-27b"
          q36: "qwen3.6-35b-a3b"
          g31: "gemma-4-31b"
          g26: "gemma-4-26b-a4b"
          mg30: "muse-glimmer-30b"
          q35: "qwen3.5-9b"
          # AFFiNE + LiteLLM route embed calls to 0.6b; must be in-matrix or llama-swap
          # evicts the chat model when embedding starts (exclusive default).
          emb: "qwen3-embedding-0.6b"
          rr: "bge-reranker-v2-m3"
          # mnemo's reranker; bge stays for AFFiNE (routed by name via LiteLLM).
          qrr: "qwen3-reranker-4b"
          # Speech: subset semantics make these optional co-residents; without
          # set membership their first request would evict the pinned chat model.
          asr: "qwen3-asr-0.6b"
          tts: "qwen3-tts-0.6b"
        evict_costs:
          q3827: 25
          q36: 25
          g31: 25
          g26: 20
          mg30: 25
          q35: 10
          emb: 2
          rr: 3
          qrr: 4
          asr: 2
          tts: 2
        sets:
          # One chat model + embedding + a reranker — either reranker may be
          # co-resident so mnemo RAG / AFFiNE calls never evict the chat model.
          # muse-glimmer-30b stays outside the group (exclusive swap-in).
          llm: "(q3827 | q36 | g31 | g26 | q35) & emb & (rr | qrr) & asr & tts"
    YAML

    "audiocpp-asr.json" = jsonencode({
      host      = "127.0.0.1"
      port      = 9200 # overridden by --port
      backend   = "cuda"
      device    = 0
      lazy_load = false
      models = [{
        id     = "qwen3-asr-0.6b"
        family = "qwen3_asr"
        path   = "/models/audiocpp/models/Qwen3-ASR-0.6B-GGUF"
        task   = "asr"
        mode   = "offline"
      }]
    })

    "audiocpp-tts.json" = jsonencode({
      host      = "127.0.0.1"
      port      = 9201 # overridden by --port
      backend   = "cuda"
      device    = 0
      lazy_load = false
      # Drop <name>.wav + a prompt_text mapping into voices/ to add voices;
      # requests select them via the OpenAI `voice` field.
      voice_dir = "/models/audiocpp/voices"
      models = [{
        id     = "qwen3-tts-0.6b"
        family = "qwen3_tts"
        path   = "/models/audiocpp/models/Qwen3-TTS-12Hz-0.6B-Base-GGUF"
        task   = "tts"
        mode   = "offline"
      }]
    })
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "llama_swap" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubernetes_persistent_volume_claim_v1.gpu_model_storage,
  ]

  metadata {
    name      = "llama-swap"
    namespace = local.llama_swap_ns
    labels    = local.llama_swap_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.llama_swap_labels
    }

    template {
      metadata {
        labels = local.llama_swap_labels
        annotations = {
          "aether.shdr.ch/config-sha" = sha256(jsonencode(kubernetes_config_map_v1.llama_swap_config.data))
        }
      }

      spec {
        runtime_class_name = "nvidia"

        node_selector = local.gpu_neo_node_selector

        init_container {
          name  = "init-storage"
          image = "busybox:latest"
          # Idempotent: mount the PVC root (no sub_path) and only ensure the
          # sub-path exists + is world-writable. Must NOT chmod -R the
          # populated tree — it's 170+ GB of GGUFs and would re-walk on every
          # restart.
          command = ["sh", "-c", "mkdir -p /gpu-storage/${local.llama_swap_subpath} && chmod 777 /gpu-storage/${local.llama_swap_subpath}"]

          # Limits on the init container are required for the POD-level
          # cgroup memory.max: kubelet only sets it when every container
          # (init included) has a limit, and Talos's OOM controller only
          # spares cgroups with memory.max set (2026-08-04: 303 PSI-sweep
          # kills against this pod's cgroup).
          resources {
            requests = { cpu = "50m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          volume_mount {
            name       = "models"
            mount_path = "/gpu-storage"
          }
        }

        init_container {
          name  = "install-audiocpp"
          image = local.audiocpp_image
          # Copies audiocpp_server + its libs from the official image onto the
          # PV so llama-swap can spawn it as a child process. Marker-guarded:
          # re-copies only when audiocpp_image_tag changes.
          command = ["bash", "-c", <<-EOT
            set -e
            D=/gpu-storage/${local.llama_swap_subpath}/audiocpp
            if [ "$(cat "$D/.image-marker" 2>/dev/null)" != "${local.audiocpp_image_tag}" ]; then
              rm -rf "$D/bin.tmp" "$D/bin"
              mkdir -p "$D/bin.tmp" "$D/models" "$D/voices"
              cp -r /app/. "$D/bin.tmp/"
              mv "$D/bin.tmp" "$D/bin"
              echo "${local.audiocpp_image_tag}" > "$D/.image-marker"
            fi
          EOT
          ]

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          volume_mount {
            name       = "models"
            mount_path = "/gpu-storage"
          }
        }

        container {
          name  = "llama-swap"
          image = local.llama_swap_image
          args  = ["-config", "/config/config.yaml"]

          port {
            container_port = local.llama_swap_port
            name           = "http"
          }

          env {
            name  = "LLAMA_CACHE"
            value = "/models"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }

          volume_mount {
            name       = "models"
            mount_path = "/models"
            sub_path   = local.llama_swap_subpath
          }

          resources {
            requests = {
              cpu              = "250m"
              memory           = "8Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              # 56Gi (was 40, was 32): sized to the VPA/goldilocks
              # recommendation (56.8G observed need). History: 32Gi +
              # --no-mmap gemma = 48 OOM kills/day (2026-08-03); 40Gi still
              # memcg-OOM-looped on model reloads, and each reload's page-
              # cache churn drove node PSI past the Talos 1.12.1 OOM trigger
              # — this sweep-immune pod's churn got cilium/kube-apiserver
              # killed as collateral (adversarial review, 2026-08-05;
              # docs/worklogs/talos-oom-sweeps-2026-08.md). Weights stay
              # mmap'd/reclaimable; the limit must fit the full co-resident
              # set's host buffers, not just the pinned model.
              memory           = "56Gi"
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.llama_swap_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.llama_swap_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.llama_swap_config.metadata[0].name
          }
        }

        volume {
          name = "models"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.gpu_model_storage.metadata[0].name
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

resource "kubernetes_service_v1" "llama_swap" {
  metadata {
    name      = "llama-swap"
    namespace = local.llama_swap_ns
    labels    = local.llama_swap_labels
  }

  spec {
    selector = local.llama_swap_labels

    port {
      port        = local.llama_swap_port
      target_port = local.llama_swap_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "llama_swap_route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "llama-swap"
      namespace = local.llama_swap_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.llama_swap_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.llama_swap.metadata[0].name
          port = local.llama_swap_port
        }]
      }]
    }
  }
}
