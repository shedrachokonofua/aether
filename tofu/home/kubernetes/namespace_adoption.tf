# =============================================================================
# Namespace state adoption (moved + import)
# =============================================================================

moved {
  from = kubernetes_namespace_v1.affine
  to   = module.namespace["affine"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.ceph_csi_fs
  to   = module.namespace["ceph-csi-cephfs"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.cnpg_system
  to   = module.namespace["cnpg-system"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.coder
  to   = module.namespace["coder"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.dawarich
  to   = module.namespace["dawarich"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.descheduler
  to   = module.namespace["descheduler"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.deskplane
  to   = module.namespace["deskplane"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.games
  to   = module.namespace["games"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.gitlab_runner
  to   = module.namespace["gitlab-runner"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.globalping
  to   = module.namespace["globalping"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.goldilocks
  to   = module.namespace["goldilocks"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.holyclaude
  to   = module.namespace["holyclaude"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.hoppscotch
  to   = module.namespace["hoppscotch"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.immich
  to   = module.namespace["immich"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.infra
  to   = module.namespace["infra"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.istio_system
  to   = module.namespace["istio-system"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.karakeep
  to   = module.namespace["karakeep"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.kepler
  to   = module.namespace["kepler"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.knative_serving
  to   = module.namespace["knative-serving"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.matrix
  to   = module.namespace["matrix"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.media
  to   = module.namespace["media"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.miniflux
  to   = module.namespace["miniflux"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.nextcloud
  to   = module.namespace["nextcloud"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.open_design
  to   = module.namespace["open-design"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.personal
  to   = module.namespace["personal"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.policy_reporter
  to   = module.namespace["policy-reporter"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.sandboxes
  to   = module.namespace["sandboxes"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.system
  to   = module.namespace["system"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.temporal
  to   = module.namespace["temporal"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.tetragon
  to   = module.namespace["tetragon"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.trivy_operator
  to   = module.namespace["trivy-system"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.vcluster_seven30
  to   = module.namespace["vc-seven30"].kubernetes_namespace_v1.this
}

moved {
  from = kubernetes_namespace_v1.yourspotify
  to   = module.namespace["yourspotify"].kubernetes_namespace_v1.this
}
