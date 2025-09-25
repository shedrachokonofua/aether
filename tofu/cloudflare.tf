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
  content = "\"v=spf1 include:_spf.protonmail.ch ~all\""
  type    = "TXT"
  zone_id = cloudflare_zone.shdrch_domain.id
  proxied = false
  ttl     = 1

  lifecycle {
    prevent_destroy = true
  }
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
