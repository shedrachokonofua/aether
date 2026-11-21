# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see docs/orion.md.
locals {
  orion_release = "5f6b20c17e39feec0455ada833569504d37ff5f3"
}
