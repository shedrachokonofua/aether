# Orion chart release: pins chart `0.1.0-g<sha>` (Deployment shape, Agents,
# prompts, grants, orion-skills). The app image is NOT pinned here: it runs
# main:latest and Keel rolls each new digest. Bump this SHA when a main commit
# changes the chart; see docs/orion.md.
locals {
  orion_release = "194f6d9d127e6e135a56eda3176269b7986e26b3"
}
