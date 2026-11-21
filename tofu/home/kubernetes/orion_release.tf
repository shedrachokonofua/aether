# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see docs/orion.md.
locals {
  orion_release = "b3562c04c49a3f05c75f79927be9003362673577"
}
