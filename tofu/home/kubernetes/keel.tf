# =============================================================================
# Keel — image auto-updater for GitLab-backed :latest workloads
# =============================================================================
# Keel (keel.sh) watches Deployments carrying keel.sh/* annotations and
# force-updates them when the digest behind a fixed tag (:latest) changes in the
# private GitLab registry. Only OUR CI-built images opt in: orion, composer,
# litellm's espn-mcp + finviz-mcp-server sidecars, mnemo, and deskplane.
# Third-party :latest sidecars are excluded per-workload via
# keel.sh/monitorContainers.
#
# Coexistence with OpenTofu (code is the source of truth):
#   * Keel keeps the image string as ":latest", so tofu sees no image diff.
#   * On a new digest Keel patches the LIVE Deployment: it writes
#     spec.template.metadata.annotations["keel.sh/update-time"] (the rollout
#     trigger) and metadata.annotations["kubernetes.io/change-cause"]. Both are
#     excluded via lifecycle.ignore_changes on every managed native Deployment
#     (orion/composer/litellm). Helm-managed Deployments (mnemo/deskplane) are
#     opted in with kubernetes_annotations, whose field manager owns only the
#     keel.sh/* keys, so Keel's writes never fight tofu.
#   * Registry auth for polling reuses each workload's existing imagePullSecret —
#     Keel merges spec.template.spec.imagePullSecrets automatically, so no
#     cluster-wide DOCKER_REGISTRY_CFG is required.
#
# Keel owns which build runs; tofu state no longer records the live digest.
# Rollback = repush/repin the image tag, not a tofu revert.

resource "helm_release" "keel" {
  depends_on = [helm_release.cilium, module.namespace["keel"]]

  name       = "keel"
  repository = "https://keel-hq.github.io/keel"
  chart      = "keel"
  version    = "v1.0.5" # app 0.20.0 — latest published chart
  namespace  = module.namespace["keel"].name
  wait       = true
  timeout    = 300

  values = [yamlencode({
    # Poll registries for new :latest digests. Per-workload keel.sh/pollSchedule
    # can override this global default.
    polling = {
      enabled         = true
      defaultSchedule = "@every 1m"
    }

    # Kubernetes provider only. The Helm provider would run `helm upgrade` and
    # fight OpenTofu, which owns the mnemo/deskplane releases — keep it off and
    # let Keel patch the live Deployments directly.
    helmProvider = {
      enabled = false
    }

    # Headless controller: no admin UI / LoadBalancer service.
    service = {
      enabled = false
    }

    # Cluster-scoped RBAC so Keel can watch/patch workloads in every app
    # namespace and read their imagePullSecrets for registry polling.
    rbac = {
      enabled = true
    }

    # Route update notifications to the Apprise gateway. Keel POSTs
    # {name, message, createdAt, type, level}. Apprise reserves `type` for its
    # severity enum and rejects Keel's `type="deployment update"`, so the remap
    # consumes it as the title (`:type=title`, == Keel's `name`) and feeds
    # `message` -> body (`:message=body`); the other keys are ignored. Routed to
    # the `standard` group (ntfy /alerts push + Matrix #alerts) so updates
    # actually reach a device, not just chat. Level `success` sends one message
    # per applied update (plus failures), skipping the info-level "preparing to
    # update" chatter.
    notificationLevel = "success"
    webhook = {
      enabled  = true
      endpoint = "https://apprise.home.shdr.ch/notify/aether?tags=standard&:message=body&:type=title"
    }
  })]
}
