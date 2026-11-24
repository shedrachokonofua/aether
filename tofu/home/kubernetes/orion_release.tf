# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see docs/orion.md.
locals {
  orion_release = "9f597ed63fd3fdf478a260a407f3d4ea4c76f5a7"
}
