# Orion release: one main commit pins both the image `main:<sha>` and the
# chart `0.1.0-g<sha>` (CI publishes both per main commit). Deploy by setting
# this SHA once its pipeline has published them; see README "Orion".
locals {
  orion_release = "9a54e6111d77e6a2c9b082805294e6716d067301"
}
