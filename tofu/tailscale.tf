resource "tailscale_dns_nameservers" "tailnet_nameservers" {
  nameservers = [
    "10.0.0.1",
  ]
}

resource "tailscale_acl" "tailnet_acl" {
  acl = jsonencode({
    acls: [
      // Allow all traffic
      {
        action: "accept",
        src: ["*"],
        dst: ["*:*"],
      }
    ],
    ssh: [
      // Allow all users to SSH into their own machines
      {
        action: "check",
        src: ["autogroup:member"],
        dst: ["autogroup:self"],
        users: ["autogroup:nonroot", "root"],
      }
    ],
    nodeAttrs: [
      // Allow all users to control Funnel for their own machines
      {
        target: ["autogroup:member"],
        attr: ["funnel"],
      }
    ],
    tagOwners: {
      "tag:aether": [local.tailscale.user]
    },
    autoApprovers: {
      // Allow auto-approval for subnet router in home network
      routes: {
        "10.0.0.0/8": ["tag:aether"],
        "192.168.0.0/16": ["tag:aether"],
      }
    }
  })
}
