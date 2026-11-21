# Proof-Gated Payee on HSK Chain

**HSK Chain Horizon Hackathon · Seoul (DoraHacks) — Track: Agent Payments & A2A Settlement**
Team rezimx-btc (solo) · Submission deadline: **3 Dec 2026, 13:00 KST (11:00 WIB)** · Demo Day 5 Dec 2026

> *No payment leaves escrow until the payee, the amount, and the mandate are
> all proven — an autonomous verification agent stands between the payer's
> funds and the recipient.*

## The problem

AI agents are starting to pay each other: one agent hires another, settles an
invoice, splits a payout. The payment itself is easy — the verification is
missing. A recipient agent can be spoofed, compromised, or simply wrong, and a
blind payment mandate drains the payer with no check, no cap, and no audit
trail.

## How it works

```
Payer (agent / user)
   │ 1. createInvoice(payee, amount, purpose, expiry) + fund escrow
   ▼
ProofGatedPayeeHSK (HSK Chain, Solidity 0.8.24)
   ├── payee registry: registerPayee / revokePayee (allowlist)
   ├── session keys: authorizeAgent (agent may ONLY release, never withdraw)
   ├── spending limits: setSpendingLimit(agent, cap, window)
   ├── views: verifyPayee / canRelease / remainingSpend
   ├── release (gated) / releaseWithMandate / refund / cancelInvoice
   └── events: InvoiceCreated, Released, Refunded, PayeeRegistered/Revoked,
       AgentAuthorized/Revoked, LimitSet — full on-chain audit trail
   │ 2. verifier agent checks the mandate off-chain, releases on-chain
   ▼
Verifier agent (Node, ethers v6) + CLI demo
   ├── runs the 5 gate checks, signs/releases via the session key when PASS
   └── refuses + triggers the full-refund path when FAIL
```

**The 5 gates** (every release must pass all of them):

1. Payee is on the allowlist
2. Amount is within the agent's remaining spend for the current window
3. Mandate signature recovers to the invoice payer (verified on-chain too)
4. Mandate / invoice unexpired
5. Purpose matches the invoice

**Security model:** session key can only `release`, never withdraw; an agent
without a cap has cap 0 and cannot release; per-invoice expiry; **no owner
backdoor over escrowed funds** — the owner administers only the registry,
session keys and limits, and cannot move escrowed funds (the only exits are
`release` to the registered payee and `refund`/`cancelInvoice` to the payer);
Checks-Effects-Interactions + reentrancy lock; custom errors; plain transfers
rejected (funds may only enter via `createInvoice`).

## Network facts (verified live, 21 Nov 2026)

| Item | Value | How verified |
|---|---|---|
| HSK Chain testnet RPC | `https://testnet.hsk.xyz` | `eth_chainId` → `0x85` = **133** |
| HSK Chain mainnet RPC | `https://mainnet.hsk.xyz` | `eth_chainId` → `0xb1` = **177** |
| Testnet block explorer | `https://testnet-explorer.hskchain.net` (Blockscout; API `…/api` answers) | live `ethsupply` query |
| Testnet faucet (official) | `https://faucet.hskchain.net/faucet` — "Send Me 1 HSK", 1 HSK / 24 h | page fetched; **needs Google reCAPTCHA in a browser** |
| Testnet faucet (alt) | thirdweb universal faucet, 0.01 tHSK/day | needs wallet connect in browser |

✅ **DEPLOYED 21 Nov 2026, 22:35 WIB** — contract live + verified on the
Blockscout explorer (see § Deploy for addresses and tx hashes). The faucet
paid **0.1 tHSK** (the button said 1 HSK), tx
`0x5439f355c6b855f0a518f3e4b6aab5ca085b8e08678b6ea0c8d69900c9974853`.
**Never deploy to mainnet; no mainnet funds are used anywhere in this repo.**

## HSP (HashKey Settlement Protocol) — what we verified

HSP is HashKey's on-chain settlement protocol for AI agents and hardware,
x402-compatible, built around a signed **Cart Mandate** (payer, payee,
amount, purpose, expiry + signature) with webhook settlement callbacks. We
could **not** verify any public HSP developer API, API key flow, or sandbox
endpoint — HSP is a merchant/enterprise integration surface, not a public
testnet API. So this repo does **not** call or fake HSP: the mandate struct
in `ProofGatedPayeeHSK` and `agent/src/mandate.js` follows the published
Cart Mandate shape exactly (same fields, payer-signed), and the contract
verifies the payer's signature on-chain. If the track expects a live HSP
integration, that needs a HashKey merchant/API key — flagged as OPEN.

## Repo layout

```
dorahacks-hskchainseoul/
├── DESIGN.md            ← design (prose) this build implements
├── README.md            ← this file
├── LICENSE              ← MIT
├── contracts/           ← Foundry project
│   ├── src/ProofGatedPayeeHSK.sol
│   ├── test/ProofGatedPayeeHSK.t.sol   (35 tests)
│   └── script/Deploy.s.sol
├── agent/               ← verifier agent + CLI demo (Node, ethers v6)
│   ├── src/abi.js src/mandate.js src/verifier.js src/cli.mjs
│   └── .env.example
└── docs/
    ├── demo-script.md
    └── demo-output-anvil.txt   ← full local demo log
```

## Build + test

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd contracts && forge test        # 35/35 pass
cd ../agent && npm install
```

## Deploy (HSK Chain testnet ONLY)

```bash
# 1. Fund the deployer with testnet tHSK (ONE browser step):
#    open https://faucet.hskchain.net/faucet, paste the deployer address,
#    solve the captcha, click "Send Me 1 HSK" (1 HSK / 24 h).
#    Deployer address: see .secrets/deployer.json (fresh testnet-only key,
#    chmod 600, gitignored — NEVER commit it, NEVER reuse it on mainnet).
# 2. Deploy + verify on the Blockscout explorer:
cd contracts
export DEPLOYER_PRIVATE_KEY=0x...   # fresh TESTNET-ONLY key, never commit
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://testnet.hsk.xyz --broadcast --verify \
  --verifier blockscout \
  --verifier-url https://testnet-explorer.hskchain.net/api
# 3. Set up (as owner): register the payee, authorize the agent session key,
#    set its spending limit — then run the testnet demo (see below).
```

Dry-run (no broadcast) already verified against the live testnet RPC:
`forge script script/Deploy.s.sol:Deploy --rpc-url https://testnet.hsk.xyz`
→ SIMULATION COMPLETE.

## Deployment — HSK Chain testnet (LIVE, 21 Nov 2026 22:35 WIB)

| Item | Value |
|---|---|
| Contract `ProofGatedPayeeHSK` | `0x2dE5fa0531148a3535659035EDDDdf75e2552E06` |
| Deploy tx | `0xb8eb14f3acf6cf31e357d42607734849c5fc92a5f67194a466f14ce3c24a6ccb` |
| Deploy block | 36044397 (status 0x1, gasUsed 3,580,605) |
| Owner (deployer) | `0xcd3CD4c620aa0bAa0Df31Ddaf6e8713d5968397F` |
| Source verification | Blockscout "Pass - Verified" |
| Explorer | https://testnet-explorer.hskchain.net/address/0x2dE5fa0531148a3535659035EDDDdf75e2552E06 |
| Faucet in | 0.1 tHSK, tx `0x5439f355c6b855f0a518f3e4b6aab5ca085b8e08678b6ea0c8d69900c9974853` |

Setup txs (owner = deployer): fund agent 0.005 tHSK
`0x5c3c81007b4f283c71b1d9edc40d9d4b56c9de999a9d753fdff2048ad4bd64c3`;
registerPayee (payout wallet, "Vendor Kopi")
`0xa0b5e43008de55662e9e15c97481e53c2bdddcea4c7bbdc5ca47c740cddcd23f`;
authorizeAgent (agent `0xbcf436e090767ff74bD57eb24747ab80aBb713aE`)
`0xc3081efc7a2a5c5d334dd433b184d97c2ca75aac40473210a51e174c6926bb29`;
setSpendingLimit (5 tHSK / 1 day)
`0x767153bcae1d4a1afcfb181a91d3a9543a5f113e86655a0defd9b5883bae65d8`.
Agent session key: fresh testnet-only key in `agent/.env` (chmod 600,
gitignored — never committed). Payer in the demo = the deployer; payee =
the builder's payout wallet `0x3Eb09d7A08ACD5dEbC1F0b5ee83a1a344890632F`.

## Demo

```bash
cd agent && npm run demo            # local anvil: PASS + 2x FAIL flows, self-contained
```

What the demo proves (see `docs/demo-output-anvil.txt`):

- **FLOW 1 — PASS:** mandate valid → all 5 gates PASS → agent releases 1 ETH
  to the registered payee (`RELEASED`, payee +1.0 ETH).
- **FLOW 2 — FAIL:** payee revoked from the allowlist → gate 1 FAIL, contract
  `canRelease` says "payee not registered" → release reverts → payer refunded
  in full (+0.9999… ETH net of gas).
- **FLOW 3 — FAIL:** mandate amount tampered 1 → 2 ETH (signature not
  re-signed) → gate 3 FAIL (signature recovers to a stranger) → release
  reverts → payer refunded in full.

Testnet demo (after deploy + setup):

```bash
CONTRACT_ADDRESS=0x... PAYER_PRIVATE_KEY=0x... AGENT_PRIVATE_KEY=0x... \
  PAYEE_ADDRESS=0x... DEMO_AMOUNT_ETH=0.01 npm run demo:testnet
```

**Testnet demo ran LIVE 21 Nov 2026, 22:41 WIB** (invoices #3–#5; full log
`docs/demo-testnet.typescript`, timing `docs/demo-testnet.timing`):

- **FLOW 1 — PASS:** invoice #3, 5/5 gates PASS, RELEASED payee +0.01 tHSK
  (create `0x25cee0f4ad9ba1698a728d2546c763c8b1e0484ae41ba33b6147a29e61eea085`,
  release `0x4f2f82f957de5f83ee0a5420faf0e2e2f26a6d40611ddf00766211815d3f24d7`).
- **FLOW 2 — FAIL:** invoice #4, payee revoked → gate 1 FAIL, contract
  `canRelease`: "payee not registered", release reverted, REFUNDED in full
  (`0xfffc6730270a9f18eeeebdd228dc1676b948295cc433ef7ffbf0c275c15f45c0`).
- **FLOW 3 — FAIL:** invoice #5, mandate amount tampered 0.01 → 0.02 tHSK
  without re-signing → gate 3 FAIL (signature recovers to a stranger),
  release reverted, REFUNDED in full
  (`0xb0d26b9ba298998344319d9875a751a4f24755efcb1a724de6ca7c989fe67bc9`).

Final on-chain state after the demo: contract balance 0.0 tHSK, payee
+0.02 tHSK total (2 releases), `nextInvoiceId` 6, deployer 0.0698 tHSK.

> **Caveat, stated honestly:** the testnet demo uses `DEMO_AMOUNT_ETH=0.01`
> (0.01 tHSK per invoice) because the faucet paid 0.1 tHSK, not 1 — the
> default 1 ETH applies only to the local anvil demo. The gates, the
> contract calls, and the PASS/FAIL logic are identical at either amount;
> only the funded value differs. An earlier testnet run (invoices #0–#2)
> had two hardcoded "1 ETH" log lines while the real amount was 0.01;
> those lines were fixed to print the actual amount and the demo was
> re-run — the recording below is the corrected run.

Video demo: `video/hsk-proof-gated-payee-demo.mp4` — 69.2 s, 1280×720,
H.264, sha256
`93c2ca4fb148c904b710c02a2ab54ca59ca4002b5fa8d3b65bc66ca6726bd442`
(rendered verbatim from the live `script -T` recording with
`docs/render-demo-video.py`; idle gaps capped at 12 s — none exceeded it).

## Open items (for the coordinator)

1. **Faucet / testnet deploy — RESOLVED 21 Nov 2026.** Faucet paid 0.1 tHSK
   (not 1 as labelled); deploy + setup + demo all live on testnet (see §
   Deployment above). No further faucet claims needed for this build.
2. **Seoul mainnet requirement UNVERIFIED** — the Mumbai edition required
   mainnet deployment; the Seoul DoraHacks page returned HTTP 405 to the
   crawler on 21 Nov. Do NOT deploy to mainnet without an explicit user
   order. Confirm the rubric + submission form via the live browser.
3. **HSP live integration** — no public API/key flow could be verified;
   mandate follows the published Cart Mandate shape without faking HSP.
4. **Submission** — public repo `rezimx-btc/hsk-proof-gated-payee` (to be
   created at submit time) + demo video (<3 min) + DoraHacks form, before
   3 Dec 2026 11:00 WIB.
