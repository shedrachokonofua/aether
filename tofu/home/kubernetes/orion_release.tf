# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see docs/orion.md.
locals {
  orion_release = "c5bcc9f47fb1df8a927db2db0c1a57dc7e6c6c9a"
}
