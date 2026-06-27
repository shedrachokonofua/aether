resource "cloudflare_zone" "shdrch_domain" {
  account = {
    id = local.cloudflare.account_id
  }
  name = "shdr.ch"
  type = "full"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zone_setting" "shdrch_ssl" {
  zone_id    = cloudflare_zone.shdrch_domain.id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_zone_setting" "shdrch_always_use_https" {
  zone_id    = cloudflare_zone.shdrch_domain.id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone" "seven30_domain" {
  provider = cloudflare.seven30
  account = {
    id = local.cloudflare_seven30.account_id
  }
  name = "seven30.xyz"
  type = "full"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zone_setting" "seven30_ssl" {
  provider   = cloudflare.seven30
  zone_id    = cloudflare_zone.seven30_domain.id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_zone_setting" "seven30_always_use_https" {
  provider   = cloudflare.seven30
  zone_id    = cloudflare_zone.seven30_domain.id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_dns_record" "aether_public_gateway_root" {
  name    = "@"
  content = module.aws.public_gateway_ip
  type    = "A"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = true
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "aether_public_gateway_wildcard" {
  name    = "*"
  content = module.aws.public_gateway_ip
  type    = "A"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = true
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
}

# tv.shdr.ch - Direct access for Jellyfin (bypasses Cloudflare proxy for video ToS)
# Protected by CrowdSec on the public gateway instead of Cloudflare WAF
resource "cloudflare_dns_record" "aether_public_gateway_tv" {
  name    = "tv"
  content = module.aws.public_gateway_ip
  type    = "A"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 300
}

# nextcloud.shdr.ch - Direct access for Nextcloud sync and large uploads.
# Protected by CrowdSec on the public gateway instead of Cloudflare WAF.
resource "cloudflare_dns_record" "aether_public_gateway_nextcloud" {
  name    = "nextcloud"
  content = module.aws.public_gateway_ip
  type    = "A"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 300
}

resource "cloudflare_dns_record" "aether_public_gateway_seven30_root" {
  provider = cloudflare.seven30
  name     = "@"
  content  = module.aws.public_gateway_ip
  type     = "A"
  zone_id  = cloudflare_zone.seven30_domain.id
  proxied  = true
  ttl      = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "aether_public_gateway_seven30_wildcard" {
  provider = cloudflare.seven30
  name     = "*"
  content  = module.aws.public_gateway_ip
  type     = "A"
  zone_id  = cloudflare_zone.seven30_domain.id
  proxied  = true
  ttl      = 1
}

resource "cloudflare_dns_record" "shdr_ch_dkim_protonmail" {
  name    = "protonmail._domainkey.shdr.ch"
  content = "protonmail.domainkey.doppwpp2flj65ryomxwk7mre2jvwcrl2wvszn5cbvpxo5blaw2yfa.domains.proton.ch"
  type    = "CNAME"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "shdr_ch_dkim_protonmail2" {
  name    = "protonmail2._domainkey.shdr.ch"
  content = "protonmail2.domainkey.doppwpp2flj65ryomxwk7mre2jvwcrl2wvszn5cbvpxo5blaw2yfa.domains.proton.ch"
  type    = "CNAME"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
}


resource "cloudflare_dns_record" "shdr_ch_dkim_protonmail3" {
  name    = "protonmail3._domainkey.shdr.ch"
  content = "protonmail3.domainkey.doppwpp2flj65ryomxwk7mre2jvwcrl2wvszn5cbvpxo5blaw2yfa.domains.proton.ch"
  type    = "CNAME"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "shdr_ch_mx_protonmail_primary" {
  name     = "shdr.ch"
  content  = "mail.protonmail.ch"
  type     = "MX"
  priority = 10
  zone_id  = cloudflare_zone.shdrch_domain.id
  proxied  = false
  ttl      = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "shdr_ch_mx_protonmail_secondary" {
  name     = "shdr.ch"
  content  = "mailsec.protonmail.ch"
  type     = "MX"
  priority = 20
  zone_id  = cloudflare_zone.shdrch_domain.id
  proxied  = false
  ttl      = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "shdr_ch_dmarc" {
  name    = "_dmarc.shdr.ch"
  content = "\"v=DMARC1; p=quarantine; rua=mailto:3468988e99d54c95aacf348d4d3c4542@dmarc-reports.cloudflare.net;\""
  type    = "TXT"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "shdr_ch_spf" {
  name    = "shdr.ch"
  content = "\"v=spf1 include:_spf.protonmail.ch include:amazonses.com ~all\""
  type    = "TXT"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
}

# AWS SES DKIM records for email authentication
resource "cloudflare_dns_record" "shdr_ch_ses_dkim" {
  count   = 3
  name    = "${module.aws.ses_domain_dkim_tokens[count.index]}._domainkey.shdr.ch"
  content = "${module.aws.ses_domain_dkim_tokens[count.index]}.dkim.amazonses.com"
  type    = "CNAME"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1
}

# AWS SES domain verification TXT record
resource "cloudflare_dns_record" "shdr_ch_ses_verification" {
  name    = "_amazonses.shdr.ch"
  content = "\"${module.aws.ses_domain_verification_token}\""
  type    = "TXT"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "shdr_ch_protonmail_verification" {
  name    = "shdr.ch"
  content = "\"protonmail-verification=3d35cf0118ffc020071fb50798efae703760474c\""
  type    = "TXT"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "random_id" "uptime_monitor_tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "uptime_monitor_tunnel" {
  account_id    = local.cloudflare.account_id
  name          = "aether-uptime-monitor"
  tunnel_secret = random_id.uptime_monitor_tunnel_secret.b64_std
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "uptime_monitor_tunnel_config" {
  account_id = local.cloudflare.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.uptime_monitor_tunnel.id

  config = {
    ingress = [
      {
        hostname = "status.shdr.ch"
        service  = "http://localhost:3001"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "uptime_monitor_tunnel_token" {
  account_id = local.cloudflare.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.uptime_monitor_tunnel.id
}

resource "cloudflare_dns_record" "uptime_monitor_cname" {
  zone_id = cloudflare_zone.shdrch_domain.id
  name    = "status"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.uptime_monitor_tunnel.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}
