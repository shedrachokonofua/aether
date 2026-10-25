# Orion chart owns all eight feed Agents. Retain this whole-resource
# migration until all state consumers have crossed the ownership handover.
removed {
  from = kubectl_manifest.daimyo_orion_feed_agent
  lifecycle { destroy = false }
}
