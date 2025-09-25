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
      // Admin can access everything
      {
        action : "accept",
        src : ["group:admin"],
        dst : ["*:*"],
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
      // Public gateway can ONLY access home gateway public port
      {
        action : "accept",
        src : ["tag:public-gateway"],
        dst : ["tag:home-gateway:8443"],
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

resource "tailscale_dns_nameservers" "tailnet_nameservers" {
  nameservers = [
    "10.0.0.1",
  ]
}

resource "tailscale_oauth_client" "public_gateway_oauth_client" {
  description = "Public gateway Tailscale OAuth client"
  scopes      = ["auth_keys"]
  tags        = ["tag:public-gateway"]
}
