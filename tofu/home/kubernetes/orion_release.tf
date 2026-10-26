# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see README "Orion".
locals {
  orion_release = "a1d851be34142deee480744511a4cff35a51b078"
}
