# Blockchain Stack Exploration

Exploration of self-hosted cryptocurrency infrastructure for privacy, sovereignty, and verification.

## Goal

Establish sovereign cryptocurrency infrastructure that:

1. Self-custody funds
2. Privacy-preserving (don't leak addresses to third parties)
3. Leverages existing homelab infrastructure (OpenBao, monitoring, backups)
4. Enables cheap, fast payments via Lightning

## Current State

| Aspect       | Current                 | Gap                                 |
| ------------ | ----------------------- | ----------------------------------- |
| Custody      | Exchange (Coinbase/etc) | Single point of failure, can freeze |
| Privacy      | Exchange knows all      | Every tx linked to identity         |
| Verification | Trust exchange balance  | Can't independently verify          |
| Backups      | None                    | Seed phrase not secured             |

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Blockchain Stack (Smith)                             │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                        Hardware Wallet                               │   │
│   │                     (Trezor / Coldcard)                              │   │
│   │                                                                      │   │
│   │   Primary signing device · Secure element · Air-gapped option       │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    ▼                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    NixOS VM (Blockchain Node)                        │   │
│   │                    4 vCPU, 12GB RAM                                  │   │
│   │                                                                      │   │
│   │   Storage:                                                           │   │
│   │   ├── NVMe (Ceph RBD): OS, LND, Fulcrum (~150GB)                   │   │
│   │   └── HDD (Smith pool): Bitcoin, Monero chains (~800GB)            │   │
│   │                                                                      │   │
│   │   ┌──────────┐     ┌──────────┐     ┌──────────┐                   │   │
│   │   │ bitcoind │────▶│ Fulcrum  │────▶│  Wallet  │                   │   │
│   │   │  (BTC)   │     │(Electrum)│     │(Sparrow) │                   │   │
│   │   │ 600GB HDD│     │100GB NVMe│     │          │                   │   │
│   │   └──────────┘     └──────────┘     └──────────┘                   │   │
│   │        │                                                             │   │
│   │        ▼                                                             │   │
│   │   ┌──────────┐                      ┌──────────┐                   │   │
│   │   │   LND    │                      │ monerod  │────▶ Feather      │   │
│   │   │(Lightning)────▶ ThunderHub      │  (XMR)   │      Wallet       │   │
│   │   │ 20GB NVMe│                      │ 200GB HDD│                   │   │
│   │   └──────────┘                      └──────────┘                   │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    Security Layer (Existing Infra)                   │   │
│   │                                                                      │   │
│   │   OpenBao: Encrypted multisig key backup                            │   │
│   │   Monitoring: Node health, channel balance alerts                   │   │
│   │   Backups: Lightning channel state to PBS                           │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### Hardware Wallet (Required)

The foundation of self-custody. Keys never touch the internet.

| Device             | Price | Pros                               | Cons                         |
| ------------------ | ----- | ---------------------------------- | ---------------------------- |
| **Trezor Model T** | ~$180 | Open source firmware, touchscreen  | No secure element            |
| **Ledger Nano X**  | ~$150 | Secure element, Bluetooth          | Closed source, past breaches |
| **Coldcard Mk4**   | ~$150 | Air-gapped, Bitcoin-only, paranoid | Steeper learning curve       |

**Recommendation:** Coldcard for Bitcoin, Trezor if you also want Monero support.

**Purchase:** Always from official sites (trezor.io, coinkite.com). Never Amazon/eBay (supply chain attacks).

### Bitcoin Node (bitcoind)

Full validation of the Bitcoin blockchain. Verifies every transaction since 2009.

| Resource | Full Node | Pruned Node |
| -------- | --------- | ----------- |
| Storage  | ~600GB    | ~10GB       |
| RAM      | 4GB       | 2GB         |
| Sync     | 1-3 days  | 1-3 days    |

**Note:** Full node required for Electrum server. Pruned won't work.

```yaml
# Reference config (actual deployment via NixOS quadlet containers)
services:
  bitcoind:
    image: kylemanna/bitcoind
    volumes:
      - ./bitcoin-data:/bitcoin/.bitcoin
    ports:
      - "8333:8333" # P2P
      - "8332:8332" # RPC (internal only)
    command:
      - -server=1
      - -txindex=1
      - -rpcallowip=10.0.0.0/8
      - -rpcbind=0.0.0.0
      - -par=2 # Limit CPU during sync
```

### Monero Node (monerod)

Full validation of the Monero blockchain. Privacy by default.

| Resource | Value    |
| -------- | -------- |
| Storage  | ~200GB   |
| RAM      | 4-6GB    |
| Sync     | 1-2 days |

**Why Monero:** Privacy is built-in, not bolted on. All transactions are private by default—no chain analysis possible.

```yaml
services:
  monerod:
    image: sethsimmons/simple-monerod
    volumes:
      - ./monero-data:/home/monero/.bitmonero
    ports:
      - "18080:18080" # P2P
      - "18081:18081" # RPC
    command:
      - --rpc-bind-ip=0.0.0.0
      - --confirm-external-bind
      - --no-igd
      - --max-concurrency=2 # Limit CPU during sync
```

### Electrum Server (Fulcrum)

Your Bitcoin wallet talks to YOUR server instead of public Electrum servers that log addresses.

| Implementation | Language | Notes                     |
| -------------- | -------- | ------------------------- |
| **Fulcrum**    | C++      | Fast, recommended         |
| **electrs**    | Rust     | Lower memory, slower sync |

**Privacy benefit:**

```
Without Electrum Server:
  Sparrow Wallet → Public Server → Logs your addresses
                          ↑
                   Privacy leak

With Electrum Server:
  Sparrow Wallet → Your Fulcrum → Your bitcoind
                          ↑
                   All local, no leaks
```

```yaml
services:
  fulcrum:
    image: cculianu/fulcrum
    depends_on:
      - bitcoind
    volumes:
      - ./fulcrum-data:/data
    ports:
      - "50001:50001" # TCP
      - "50002:50002" # SSL
    environment:
      - BITCOIND_HOST=bitcoind
      - BITCOIND_PORT=8332
```

### Lightning Network (LND)

Instant, cheap Bitcoin payments. Layer 2 solution.

| Aspect        | Value                      |
| ------------- | -------------------------- |
| Payment speed | 1-3 seconds                |
| Payment fee   | <$0.01                     |
| Storage       | ~20GB                      |
| RAM           | 2GB                        |
| Requires      | bitcoind (already running) |

**Channel management:**

- Open 2-3 channels to well-connected nodes (ACINQ, WalletOfSatoshi, LNBig)
- Fund each with ~$50-100
- Use ThunderHub for web UI management

```yaml
services:
  lnd:
    image: lightninglabs/lnd
    depends_on:
      - bitcoind
    volumes:
      - ./lnd-data:/root/.lnd
    ports:
      - "9735:9735" # P2P
      - "10009:10009" # gRPC
    command:
      - --bitcoin.active
      - --bitcoin.mainnet
      - --bitcoin.node=bitcoind
      - --bitcoind.rpchost=bitcoind:8332

  thunderhub:
    image: apotdevin/thunderhub
    depends_on:
      - lnd
    ports:
      - "3000:3000"
    environment:
      - ACCOUNT_CONFIG_PATH=/cfg/accounts.yaml
    volumes:
      - ./thunderhub:/cfg
```

**Finding peers:** Use amboss.space or 1ml.com to find well-connected nodes. Copy their pubkey, open channel via ThunderHub.

## Integration with Existing Stack

### OpenBao (Secrets)

Store encrypted multisig key backup:

```bash
# Store seed phrase for multisig key 2 (encrypted at rest)
bao kv put secret/bitcoin/multisig-key-2 \
  seed="abandon abandon abandon..." \
  derivation="m/48'/0'/0'/2'"
```

### Monitoring (Prometheus/Grafana)

```yaml
# prometheus scrape config
- job_name: "bitcoin"
  static_configs:
    - targets: ["blockchain-stack:9332"]
  metrics_path: /metrics

- job_name: "lnd"
  static_configs:
    - targets: ["blockchain-stack:8989"]
```

**Dashboard alerts:**

- Bitcoin: block height, peer count, sync status
- Monero: sync status, peer count
- Lightning: channel balances, offline channels, pending HTLCs

### Backups

| What                  | Where                   | How                          |
| --------------------- | ----------------------- | ---------------------------- |
| Seed phrase (primary) | Paper, safe deposit box | Written by hand, never typed |
| Seed phrase (backup)  | OpenBao                 | Encrypted, for multisig key  |
| Lightning channels    | PBS + offsite           | `lncli exportchanbackup`     |
| Wallet config         | Git (without seeds)     | Derivation paths, xpubs      |

## Deployment Plan

### Phase 1: Hardware Wallet

1. Purchase hardware wallet from official source
2. Generate seed phrase ON DEVICE (never on computer)
3. Write seed phrase on paper (metal plate for fire resistance optional)
4. Store backup in separate physical location
5. Transfer small amount from exchange to test
6. Verify can receive, then withdraw rest

### Phase 2: NixOS VM Setup

1. Add VM config to `config/vm.yml` (4 vCPU, 12GB RAM)
2. Create Tofu resources:
   - Primary disk on Ceph RBD (~150GB NVMe) for OS, LND, Fulcrum
   - Secondary disk on Smith HDD pool (~800GB) for blockchain data
3. Create NixOS configuration in `nix/hosts/smith/blockchain-stack/`
4. Add to `flake.nix` nixosConfigurations
5. Deploy with `nixos-rebuild switch --target-host`

### Phase 3: Blockchain Sync

1. Deploy bitcoind + monerod (via quadlet containers or native services)
2. Mount HDD disk to `/var/lib/blockchain`
3. Start sync (3-5 days for both chains on HDD)
4. Limit CPU with `-par=2` / `--max-concurrency=2`

### Phase 4: Electrum Server

1. Wait for bitcoind to fully sync
2. Deploy Fulcrum (stores index on NVMe root)
3. Initial index build: 12-24 hours
4. Configure Sparrow wallet to use your server

### Phase 5: Lightning

1. Deploy LND + ThunderHub (stores on NVMe root)
2. Create wallet, backup seed to OpenBao
3. Fund on-chain wallet
4. Open 2-3 channels to well-connected nodes
5. Test with small payment

## Resource Requirements

| Component       | vCPU | RAM  | Disk  | Storage | Notes                              |
| --------------- | ---- | ---- | ----- | ------- | ---------------------------------- |
| Bitcoin Node    | 2    | 4GB  | 600GB | HDD     | Bulk data, sequential after sync   |
| Monero Node     | 1    | 4GB  | 200GB | HDD     | Bulk data, sequential after sync   |
| Electrum Server | 1    | 2GB  | 100GB | NVMe    | Index queries are latency-sensitive |
| Lightning (LND) | 1    | 2GB  | 20GB  | NVMe    | Channel DB needs fast writes       |
| OS + misc       | -    | -    | 30GB  | NVMe    | Root filesystem                    |
| **Total**       | 5    | 12GB | 950GB |         |                                    |

### Hybrid Storage Layout

| Storage Type    | Contents                  | Size   | Proxmox Datastore |
| --------------- | ------------------------- | ------ | ----------------- |
| NVMe (Ceph RBD) | OS, LND, Fulcrum index    | ~150GB | ceph-vm-disks     |
| HDD (Smith)     | Bitcoin, Monero chains    | ~800GB | local-hdd         |

**Why hybrid:**

- **LND on NVMe** — Channel state DB (bbolt) needs fast, reliable writes. Slow writes risk channel force-closes.
- **Fulcrum on NVMe** — Wallet queries hit the index constantly. HDD = 100-500ms latency, NVMe = <5ms.
- **Blockchain data on HDD** — After initial sync, it's mostly sequential reads. 800GB on NVMe is wasteful.

**Host:** Smith (has 28TB HDD RAID10 + Ceph NVMe pool)

## Costs

| Item              | One-Time  | Ongoing               |
| ----------------- | --------- | --------------------- |
| Hardware wallet   | ~$150     | -                     |
| Metal seed backup | ~$30      | -                     |
| VM resources      | -         | Already have capacity |
| Storage (1TB)     | -         | Existing HDD pool     |
| Electricity       | -         | Negligible            |
| **Total**         | **~$180** | ~$0                   |

## Why NixOS (Not Kubernetes)

### Why Not Kubernetes

The blockchain stack is a poor fit for K8s:

| K8s Benefit       | Blockchain Fit                                   |
| ----------------- | ------------------------------------------------ |
| Scale to zero     | ❌ Must stay synced 24/7                         |
| Quick startup     | ❌ Days to sync if restarted cold                |
| Horizontal scale  | ❌ You don't run 3 Bitcoin replicas              |
| Service mesh      | ❌ P2P protocols, not HTTP                       |
| Multi-tenancy     | ❌ Personal node, single user                    |
| Ephemeral pods    | ❌ 1TB of state you can't lose                   |
| Storage locality  | ❌ K8s abstracts away NVMe vs HDD distinction    |

K8s excels at scale-to-zero HTTP services (LiteLLM, OpenWebUI). Blockchain is always-on, P2P, storage-heavy — the opposite pattern.

### Why NixOS

| Factor              | NixOS Benefit                                      |
| ------------------- | -------------------------------------------------- |
| Atomic rollbacks    | LND update breaks channels? Rollback in seconds    |
| Declarative config  | Entire stack is code — reproducible from git       |
| Long-lived          | No drift over years — config IS the truth          |
| Existing pattern    | Same tooling as IDS Stack, AdGuard                 |
| Hybrid storage      | Mount HDD + NVMe explicitly in filesystem config   |

The blockchain stack will run for **years** with minimal changes. NixOS's declarative model is ideal for stable, long-lived, stateful infrastructure where you want rollback safety (critical for Lightning channels).

## Decision Factors

### Pros

- Full sovereignty over funds (no exchange risk)
- Privacy (addresses not leaked to third parties)
- Verification (don't trust, verify)
- Monero for true privacy (no chain analysis)
- Lightning for cheap, instant payments
- Leverages existing infrastructure

### Cons

- Responsibility (lose seed = lose funds)
- Operational overhead (mitigated by NixOS declarative config)
- Storage requirements (~1TB hybrid NVMe + HDD)
- Initial sync time (days)
- Lightning requires attention (channel management)

### Priority

| Priority   | Component       | Rationale                           |
| ---------- | --------------- | ----------------------------------- |
| **High**   | Hardware wallet | Foundation, do this first           |
| **Medium** | Bitcoin node    | Privacy + verification              |
| **Medium** | Electrum server | Completes privacy story             |
| **Medium** | Monero node     | True privacy option                 |
| **Medium** | Lightning       | Fast payments, good uptime = viable |

## Open Questions

1. Which hardware wallet? (Coldcard vs Trezor)
2. Lightning channel funding amount? (Start with ~$100-200 total)
3. Monero wallet? (Feather Wallet recommended)

## Status

**Implementation in progress.** Hardware wallet acquired. Infrastructure created:

- [x] `config/vm.yml` - VM definition (ID 1029, 10.0.3.8, 4 vCPU, 8GB RAM)
- [x] `tofu/home/blockchain_stack.tf` - Proxmox VM + HA resource
- [x] `nix/hosts/smith/blockchain-stack/` - NixOS configuration
- [x] `flake.nix` - Added to nixosConfigurations

**Next steps:**
1. Create ZFS dataset on Smith: `zfs create -o compression=lz4 hdd/blockchain`
2. Add NFS export for the dataset
3. Apply Tofu: `task tofu:apply`
4. Deploy NixOS: `task configure:blockchain-stack`
5. Wait 3-5 days for sync, then enable LND

## Related Documents

- `kubernetes.md` — Why blockchain stays as VM (not K8s)
- `../secrets.md` — OpenBao for encrypted key backup
- `../monitoring.md` — Grafana dashboards for node metrics
- `../backups.md` — Offsite backup for Lightning channel state
- `../storage.md` — Smith HDD pool for blockchain data
- `../nixos.md` — NixOS patterns used for this VM
