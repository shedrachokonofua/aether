# =============================================================================
# Daimyo: Marrow (org seven30, project marrow)
# =============================================================================
# Marrow shapes product kits from Foundry plans (seven30/marrow). Operation
# `shape` takes a plan folder of the public seven30/foundry-plans repository,
# which the agent downloads anonymously over HTTPS (gitlab.home.shdr.ch is in
# daimyo-tasks-egress), and returns the kit as task artifact `kit.tar.gz`.
# No git grant: the org GitLab token in OpenBao stays empty.
#
# The model grant lists every model in Marrow's chains
# (seven30/marrow src/marrow/marrow.toml [models]); a model missing here fails
# at LiteLLM and Marrow benches it for the run. Marrow stops itself 10 minutes
# before the task deadline to upload the kit, and its own limit is 3h, so a
# 4h deadline leaves the engine's limit in charge.
#
# The image is seven30/marrow's CI build (.gitlab-ci.yml `image`) at the
# commit below; the revision goes Ready only with a passing attestation for
# this digest in org seven30.

locals {
  # seven30/marrow main at b064d3f (pipeline 6840, job build:image).
  marrow_image = "registry.gitlab.home.shdr.ch/seven30/marrow@sha256:ca408aca6257835193bcac320de2aad704dc9dc6f62a039cb957d235032eec8f"
  marrow_models = [
    "moira/strong",
    "moira/frontier",
    "chatgpt/gpt-6-astra",
    "kimi/k3",
    "router/minimax-m3",
    "step/step-5-preview",
    "ollama-cloud/glm-5.3",
    "ollama-cloud/deepseek-v4-pro",
    "clinepass/qwen3.8-max",
    "antigravity/gemini-3.8-flash",
    "supergrok/grok-4.7",
    "zai/glm-5.3",
  ]
}

resource "kubectl_manifest" "daimyo_marrow_project" {
  depends_on = [kubectl_manifest.daimyo_org]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Project"
    metadata = {
      name      = "marrow"
      namespace = "org-seven30"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      description = "Marrow: product kits from Foundry plans."
    }
  })
}

resource "kubectl_manifest" "daimyo_marrow_agent" {
  depends_on = [kubectl_manifest.daimyo_marrow_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "marrow"
      namespace = "org-seven30"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      project     = "marrow"
      description = "Shapes a product kit from a Foundry plan folder in seven30/foundry-plans."
      contract    = "v1"
      image       = local.marrow_image
      # TLC runs one pooled worker per spare core with -Xmx1g each; its state
      # graph is scratch under the kit in /workspace.
      resources = { cpu = "2", memory = "6Gi", workspace = "10Gi" }
      operations = [
        {
          name     = "shape"
          deadline = "4h"
          inputSchema = {
            type                 = "object"
            required             = ["plan"]
            additionalProperties = false
            properties = {
              plan = { type = "string", description = "Plan folder in seven30/foundry-plans, e.g. plans/<slug>-v<N>." }
              ref  = { type = "string", description = "Branch, tag or commit; default main." }
            }
          }
          outputSchema = {
            type     = "object"
            required = ["outcome", "kit", "plan", "rounds", "usage", "durationS"]
            properties = {
              outcome = { enum = ["ready", "needs_review"] }
              kit = {
                type     = "object"
                required = ["name", "artifact"]
                properties = {
                  name      = { type = "string" }
                  artifact  = { type = "string" }
                  features  = { type = "integer" }
                  rules     = { type = "integer" }
                  decisions = { type = "integer" }
                }
              }
              plan = {
                type     = "object"
                required = ["path", "commit"]
                properties = {
                  path   = { type = "string" }
                  commit = { type = "string" }
                }
              }
              rounds        = { type = "integer" }
              lintFindings  = { type = "integer" }
              openFindings  = { type = "integer" }
              stopped       = { type = ["string", "null"] }
              usage         = { type = "object" }
              durationS     = { type = "number" }
              fingerprint   = { type = "string" }
            }
          }
        },
      ]
      grants = [
        { name = "models", model = { models = local.marrow_models, budgetUsd = 25 } },
      ]
      endpoints = { stable = { revision = "latest" } }
    }
  })
}
