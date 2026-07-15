# AdGuard Home settings — single source of truth lives in config/adguard-settings.json
# so the nix resolver hosts (primary/secondary LXC) AND the ansible OCI resolver role
# consume identical answers (rewrites, filters, upstreams) with zero drift.
builtins.fromJSON (builtins.readFile ../../../config/adguard-settings.json)
