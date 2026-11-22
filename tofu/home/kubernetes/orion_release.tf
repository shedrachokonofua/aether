# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see docs/orion.md.
locals {
  orion_release = "8612f1866d374dca1a50a4692baeb986cc0ff4a8"
}
