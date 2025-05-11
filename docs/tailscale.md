# Tailscale

## Network Configuration

### DNS

The Tailscale network uses the home network router as its nameserver:

- Primary nameserver: `10.0.0.1` (VyOS router on home network)

### Subnet Routing

Automatic approval for subnet routing is configured for:

- `10.0.0.0/8` (Vyos network)
- `192.168.0.0/16` (Bell Gigahub network)
