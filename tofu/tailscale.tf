# Look up the home gateway device to get its stable Tailscale IP
data "tailscale_device" "home_gateway" {
  hostname = "aether-home-gateway"
  wait_for = "30s"
}

resource "tailscale_acl" "tailnet_acl" {
  acl = jsonencode({
    groups : {
      "group:admin" : [local.tailscale.user],
    },
    tagOwners : {
      "tag:home-gateway" : ["group:admin"],
      "tag:public-gateway" : ["group:admin"],
    },
    acls : [
      // Admin can access own infrastructure and own devices only
      {
        action : "accept",
        src : ["group:admin"],
        dst : [
          "tag:home-gateway:*",
          "tag:public-gateway:*",
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
        src : ["tag:home-gateway"],
        dst : [
          "10.0.0.0/8:*",
          "192.168.0.0/16:*",
        ],
      },
      // Public gateway can ONLY access home gateway caddy public port
      {
        action : "accept",
        src : ["tag:public-gateway"],
        dst : ["10.0.2.2:9443"],
      },
    ],
    autoApprovers : {
      // Auto-approve subnet routes from home gateway
      routes : {
        "10.0.0.0/8" : ["tag:home-gateway"],
        "192.168.0.0/16" : ["tag:home-gateway"],
      },
    },
  })
}

resource "tailscale_dns_split_nameservers" "home_shdr_ch" {
  domain      = "home.shdr.ch"
  nameservers = [data.tailscale_device.home_gateway.addresses[0]]
}

resource "tailscale_dns_split_nameservers" "k8s_seven30_xyz" {
  domain      = "k8s.seven30.xyz"
  nameservers = [data.tailscale_device.home_gateway.addresses[0]]
}

resource "tailscale_dns_split_nameservers" "mars_seven30_xyz" {
  domain      = "mars.seven30.xyz"
  nameservers = [data.tailscale_device.home_gateway.addresses[0]]
}

resource "tailscale_oauth_client" "public_gateway_oauth_client" {
  description = "Public gateway Tailscale OAuth client"
  scopes      = ["auth_keys"]
  tags        = ["tag:public-gateway"]
}
