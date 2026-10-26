# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see README "Orion".
locals {
  orion_release = "28f91804c85d07a4cf4c0395136b72423dd5b57f"
}
