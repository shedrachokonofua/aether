# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see README "Orion".
locals {
  orion_release = "45fbcdfe7e6bc3f6bcd67d55a40ae751b78a6d95"
}
