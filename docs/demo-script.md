# Demo script — Proof-Gated Payee on HSK Chain (< 3 min video)

Target: HSK Chain Horizon Hackathon · Seoul, track Agent Payments & A2A Settlement.
Full local log: `docs/demo-output-anvil.txt`.

## Setup (30 detik)

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd dorahacks-hskchainseoul/contracts && forge test   # 35/35 pass
cd ../agent && npm install
```

## Run

```bash
npm run demo
```

The CLI spawns a local anvil, deploys a fresh `ProofGatedPayeeHSK`, registers
a payee, authorizes the agent session key, sets a 5 ETH / 1-day spending
limit, then runs three flows. Narration cues are in brackets.

## Flow 1 — PASS (~40 dtk)

[“Payer mengunci 1 ETH di escrow untuk invoice INV-2026-0001. Agen
verifikasi mengecek mandat: payee terdaftar, jumlah dalam limit, tanda
tangan sah, belum kedaluwarsa, purpose cocok — 5 gate PASS — lalu agen
me-release. Payee terima 1 ETH, escrow 0.”]

- invoice #0 created + funded 1 ETH
- verifier: 5/5 PASS
- `RELEASED` — payee +1.0 ETH

## Flow 2 — FAIL: payee tak dikenal (~40 dtk)

[“Invoice kedua didanai, lalu payee dicabut dari allowlist. Agen menolak:
gate 1 FAIL, kontrak bilang ‘payee not registered’. Release revert — dana
tidak keluar — payer di-refund penuh.”]

- verifier: gate 1 FAIL (+ contract `canRelease`: payee not registered)
- release REVERTED
- `REFUNDED` in full — payer +0.9999… ETH (net of gas)

## Flow 3 — FAIL: mandat dipalsu (~40 dtk)

[“Invoice ketiga: penyerang ubah jumlah mandat 1 jadi 2 ETH tanpa
tanda tangan ulang. Agen menolak: tanda tangan pulih ke alamat asing.
Release revert, refund penuh.”]

- verifier: gate 3 FAIL (signature recovers to a stranger)
- release REVERTED
- `REFUNDED` in full

## Penutup (~15 dtk)

[“Tidak ada pembayaran yang lepas dari escrow sebelum payee, jumlah, dan
mandat terbukti. Gagal = refund penuh, dan setiap keputusan tercatat
on-chain.”]

## Testnet version (setelah deploy)

```bash
CONTRACT_ADDRESS=0x... PAYER_PRIVATE_KEY=0x... AGENT_PRIVATE_KEY=0x... \
  PAYEE_ADDRESS=0x... npm run demo:testnet
```

Explorer: `https://testnet-explorer.hskchain.net/address/<contract>`
