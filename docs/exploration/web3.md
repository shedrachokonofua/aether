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
│   │                    Blockchain Node VM                                │   │
│   │                    4 vCPU, 12GB RAM, 1TB HDD                        │   │
│   │                                                                      │   │
│   │   ┌──────────┐     ┌──────────┐     ┌──────────┐                   │   │
│   │   │ bitcoind │────▶│ Fulcrum  │────▶│  Wallet  │                   │   │
│   │   │  (BTC)   │     │(Electrum)│     │(Sparrow) │                   │   │
│   │   │  600GB   │     │  100GB   │     │          │                   │   │
│   │   └──────────┘     └──────────┘     └──────────┘                   │   │
│   │        │                                                             │   │
│   │        ▼                                                             │   │
│   │   ┌──────────┐                      ┌──────────┐                   │   │
│   │   │   LND    │                      │ monerod  │────▶ Feather      │   │
│   │   │(Lightning)────▶ ThunderHub      │  (XMR)   │      Wallet       │   │
│   │   │   20GB   │                      │  200GB   │                   │   │
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
# docker-compose.yml
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

### Phase 2: Blockchain Node VM

1. Create VM on Smith: 4 vCPU, 12GB RAM
2. Create ZFS dataset: `hdd/blockchain` (~1TB)
3. Deploy docker-compose with bitcoind + monerod
4. Start sync (3-5 days for both chains on HDD)
5. Limit CPU with `-par=2` / `--max-concurrency=2`

### Phase 3: Electrum Server

1. Wait for bitcoind to fully sync
2. Add Fulcrum to docker-compose
3. Initial index build: 12-24 hours
4. Configure Sparrow wallet to use your server

### Phase 4: Lightning

1. Add LND + ThunderHub to docker-compose
2. Create wallet, backup seed
3. Fund on-chain wallet
4. Open 2-3 channels to well-connected nodes
5. Test with small payment

## Resource Requirements

| Component       | vCPU | RAM  | Disk  | Notes               |
| --------------- | ---- | ---- | ----- | ------------------- |
| Bitcoin Node    | 2    | 4GB  | 600GB | HDD fine after sync |
| Monero Node     | 1    | 4GB  | 200GB | HDD fine after sync |
| Electrum Server | 1    | 2GB  | 100GB | Index size          |
| Lightning (LND) | 1    | 2GB  | 20GB  | HDD acceptable      |
| **Total**       | 5    | 12GB | 920GB |                     |

**Host:** Smith (has 28TB HDD RAID10, plenty of capacity)

**Storage:** Use `hdd/blockchain` dataset. Initial sync takes longer on HDD (~3-5 days for both chains) but performs fine afterward.

## Costs

| Item              | One-Time  | Ongoing               |
| ----------------- | --------- | --------------------- |
| Hardware wallet   | ~$150     | -                     |
| Metal seed backup | ~$30      | -                     |
| VM resources      | -         | Already have capacity |
| Storage (1TB)     | -         | Existing HDD pool     |
| Electricity       | -         | Negligible            |
| **Total**         | **~$180** | ~$0                   |

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
- Operational overhead (another VM to maintain)
- Storage requirements (~1TB)
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

**Exploration phase.** Hardware wallet is the immediate action item. Node infrastructure can follow once self-custody is established.

## Related Documents

- `../secrets.md` — OpenBao for encrypted key backup
- `../monitoring.md` — Grafana dashboards for node metrics
- `../backups.md` — Offsite backup for Lightning channel state
- `../storage.md` — Smith HDD pool for blockchain data
