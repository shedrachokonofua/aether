# Orion chart release: pins chart `0.1.0-g<sha>` (Deployment shape, Agents,
# prompts, grants, orion-skills). The app image is NOT pinned here: it runs
# main:latest and Keel rolls each new digest. Bump this SHA when a main commit
# changes the chart; see docs/orion.md.
locals {
  orion_release = "04a6e2cfbbab0c261d6b42422b52c45c2e81568d"
}
