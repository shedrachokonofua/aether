# Look up the home gateway device to get its stable Tailscale IP
data "tailscale_device" "home_gateway" {
  hostname = "aether-home-gateway"
  wait_for = "30s"
}

data "tailscale_device" "admin_gateway" {
  hostname = "aether-admin-gateway"
  wait_for = "30s"
}

locals {
  tailscale_admin_sources = [
    "group:admin",
    "autogroup:owner",
    "autogroup:admin",
  ]
}

resource "tailscale_acl" "tailnet_acl" {
  acl = jsonencode({
    groups : {
      "group:admin" : [local.tailscale.user],
    },
    tagOwners : {
      "tag:home-gateway" : local.tailscale_admin_sources,
      "tag:admin-gateway" : local.tailscale_admin_sources,
    },
    acls : [
      // Admin can access own infrastructure and own devices only
      {
        action : "accept",
        src : local.tailscale_admin_sources,
        dst : [
          "tag:home-gateway:*",
          "tag:admin-gateway:*",
          "autogroup:self:*",
          "10.0.0.0/8:*",
          "192.168.0.0/16:*",
        ],
      },
      // Shared users (co-founders via node sharing): HTTPS, DNS, GitLab SSH
      {
        action : "accept",
        src : ["autogroup:shared"],
        dst : ["tag:home-gateway:443,53,2222"],
      },
      // Home gateway can access internal networks
      {
        action : "accept",
        src : ["tag:home-gateway", "tag:admin-gateway"],
        dst : [
          "10.0.0.0/8:*",
          "192.168.0.0/16:*",
        ],
      },
    ],
    autoApprovers : {
      // Auto-approve subnet routes from the admin-only gateway
      routes : {
        "10.0.0.0/8" : ["tag:admin-gateway"],
        "192.168.0.0/16" : ["tag:admin-gateway"],
      },
    },
  })
}

resource "tailscale_dns_split_nameservers" "home_shdr_ch" {
  domain      = "home.shdr.ch"
  nameservers = [local.vm.router.ip.vyos]
}

resource "tailscale_dns_split_nameservers" "k8s_seven30_xyz" {
  domain      = "k8s.seven30.xyz"
  nameservers = [local.vm.router.ip.vyos]
}

resource "tailscale_dns_split_nameservers" "mars_seven30_xyz" {
  domain      = "mars.seven30.xyz"
  nameservers = [local.vm.router.ip.vyos]
}

resource "tailscale_oauth_client" "admin_gateway_oauth_client" {
  description = "Admin gateway Tailscale OAuth client"
  scopes      = ["auth_keys"]
  tags        = ["tag:admin-gateway"]
}

# vigil cloud-audit forwarder — read-only tailnet state (devices, ACL, keys).
# Scopes verified against https://tailscale.com/kb/1623/.
resource "tailscale_oauth_client" "cloud_audit" {
  description = "cloud-audit vigil read-only OAuth client"
  scopes      = ["devices:core:read", "policy_file:read", "auth_keys:read"]
}
