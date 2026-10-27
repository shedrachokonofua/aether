# =============================================================================
# Trip planner - Daimyo agent for cash trip planning
# =============================================================================
# `trip-planner` (org personal) plans and prices trips: flights, lodging,
# ground transport, entry rules, and a booking order. Its tools:
#   - flights:     fli, a self-hosted Google Flights MCP server (below)
#   - kiwi, skiplagged, trivago, ferryhopper: keyless public MCP servers
#   - web:         Deskplane's MCP server (search, scrape, documents)
# Skills live in trip_planner/skills/ and ship as the `trip-planner`
# ConfigBundle; they adapt borski/travel-hacking-toolkit (MIT, see
# trip_planner/skills/trip-planning/NOTICE.md) to cash-only planning.
# Network path: daimyo_tasks_egress (daimyo.tf) admits personal-tasks pods
# to fli and to the public MCP hosts in local.trip_planner_public_mcp_hosts.

locals {
  fli_ns     = module.namespace["fli"].name
  fli_port   = 8000
  fli_labels = { app = "fli" }
  # punitarani/fli main at 881aee5 (2026-09-20); multi-arch index digest.
  fli_image = "ghcr.io/punitarani/fli:sha-881aee5@sha256:3f2cce77d7d60f0ada3ca5e70143eccee4ec2fe8d19423a80d086838f1803082"
  fli_url   = "http://fli.${local.fli_ns}.svc.cluster.local:${local.fli_port}/mcp"

  trip_planner_orgs = ["personal"]
  trip_planner_public_mcp_hosts = [
    "mcp.kiwi.com",
    "mcp.skiplagged.com",
    "mcp.trivago.com",
    "mcp.ferryhopper.com",
  ]

  # Bump when a file under trip_planner/skills changes: ConfigBundle versions
  # are append-only, so add a new entry below and repoint the agent.
  trip_planner_bundle_version = 1
  trip_planner_skill_files = {
    for rel in fileset("${path.module}/trip_planner", "skills/**") :
    rel => file("${path.module}/trip_planner/${rel}")
  }
}

# =============================================================================
# fli - Google Flights MCP server
# =============================================================================

resource "kubernetes_deployment_v1" "fli" {
  metadata {
    name      = "fli"
    namespace = local.fli_ns
    labels    = local.fli_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.fli_labels
    }

    template {
      metadata {
        labels = local.fli_labels
      }

      spec {
        enable_service_links = false

        security_context {
          run_as_non_root = true
          # The image's USER is a name (appuser); give the kubelet a number.
          run_as_user = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "fli"
          image = local.fli_image

          port {
            container_port = local.fli_port
            name           = "http"
          }

          env {
            name  = "PORT"
            value = tostring(local.fli_port)
          }
          env {
            name  = "FLI_MCP_DEFAULT_CURRENCY"
            value = "CAD"
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "512Mi"
            }
          }

          # /health never calls Google, so an upstream outage does not
          # restart a healthy server.
          liveness_probe {
            http_get {
              path = "/health"
              port = local.fli_port
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.fli_port
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
        }
      }
    }
  }

  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

resource "kubernetes_service_v1" "fli" {
  metadata {
    name      = "fli"
    namespace = local.fli_ns
    labels    = local.fli_labels
  }

  spec {
    selector = local.fli_labels

    port {
      port        = local.fli_port
      target_port = local.fli_port
      name        = "http"
    }
  }
}

# =============================================================================
# Daimyo: skills bundle and agent
# =============================================================================

resource "kubectl_manifest" "daimyo_trip_planner_bundle" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "ConfigBundle"
    metadata = {
      name      = "trip-planner"
      namespace = "org-personal"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      versions = [
        {
          version  = local.trip_planner_bundle_version
          contents = { files = local.trip_planner_skill_files }
        },
      ]
    }
  })
}

resource "kubectl_manifest" "daimyo_trip_planner_agent" {
  depends_on = [kubectl_manifest.daimyo_trip_planner_bundle]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "trip-planner"
      namespace = "org-personal"
      labels    = merge(local.daimyo_cr_labels, { "orion.shdr.ch/thread" = "ask" })
    }
    spec = {
      project     = "personal"
      description = "Plans trips and prices them with live, date-specific quotes for flights, hotels and ferries; never books."
      config      = { bundle = "trip-planner", version = local.trip_planner_bundle_version }
      harness = {
        kind         = "claude-code"
        model        = "moira/strong"
        systemPrompt = <<-EOT
          You plan trips and price them with live, date-specific quotes.
          For every trip request, follow the trip-planning skill; it points
          to flight-search, lodging-and-ground, and entry-and-booking.
          Prices are cash only. Mark every price as quoted (a date-specific
          result with its source) or an estimate, and never present an
          estimate as a quote. Finish with the plan as your answer,
          followed by the sources you used.
        EOT
        skills       = ["trip-planning", "flight-search", "lodging-and-ground", "entry-and-booking"]
        tools        = { bash = true, files = true, web = false }
        maxTurns     = 200
      }
      resources  = { cpu = "1", memory = "2Gi", workspace = "2Gi" }
      operations = [{ name = "ask", deadline = "2h" }]
      grants = [
        { name = "models", model = { models = ["moira/strong"], budgetUsd = 10 } },
        {
          # Same Deskplane grant as `researcher` (token in OpenBao
          # orgs/personal/deskplane).
          name = "web"
          mcp = {
            url = "http://deskplane-mcp.deskplane.svc:8100/mcp"
            auth = {
              secret = {
                secret = { path = "orgs/personal/deskplane", key = "token" }
                header = { name = "Authorization" }
                prefix = "Bearer"
              }
            }
            tools = ["search_web", "scrape", "parse_document"]
          }
        },
        {
          name = "flights"
          mcp = {
            url   = local.fli_url
            tools = ["search_flights", "search_dates", "get_booking_options", "find_airports"]
          }
        },
        {
          name = "kiwi"
          mcp = {
            url   = "https://mcp.kiwi.com"
            tools = ["search-flight"]
          }
        },
        {
          name = "skiplagged"
          mcp = {
            url = "https://mcp.skiplagged.com/mcp"
            tools = [
              "sk_flights_search", "sk_flex_departure_calendar", "sk_flex_return_calendar",
              "sk_destinations_anywhere", "sk_resolve_iata",
              "sk_hotels_search", "sk_hotel_details", "sk_cars_search",
            ]
          }
        },
        {
          name = "trivago"
          mcp = {
            url = "https://mcp.trivago.com/mcp"
            tools = [
              "trivago-accommodation-search", "trivago-accommodation-radius-search",
              "trivago-destination-price-trends",
            ]
          }
        },
        {
          name = "ferryhopper"
          mcp = {
            url = "https://mcp.ferryhopper.com/mcp"
            tools = [
              "search_ferry_trips", "trip_details", "get_ports",
              "get_direct_connections_for_ports", "get_disruptions",
            ]
          }
        },
      ]
      sessions  = { enabled = true }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}
