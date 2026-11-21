# DESIGN.md — Proof-Gated Agent Payments on HSK Chain

**Event:** HSK Chain Horizon Hackathon · Seoul (DoraHacks)
**Team:** rezimx-btc (solo) · **Track:** Agent Payments & A2A Settlement (chosen — see §2)
**Window:** 20 Nov–5 Dec 2026 · **Submission deadline:** 3 Dec 2026, 13:00 KST = **11:00 WIB**
**Demo Day:** 5 Dec (Seoul; finalists NOT required in person — remote demo recognised)
**Prizes:** $12,000 USDT total, $6,000 per track
**Status:** RESEARCH + DESIGN (21 Nov). Build starts now.

---

## 1. The problem

AI agents are starting to pay each other (agent-to-agent, A2A): one agent hires
another, settles an invoice, splits a payout. The payment itself is easy — the
verification is missing. A recipient agent can be spoofed, compromised, or simply
wrong, and a blind payment mandate drains the payer with no check, no cap, and no
audit trail. Today's agent payments are a loaded gun: sign first, verify never.

## 2. The concept — Proof-Gated Payee on HSK Chain

**One line:** *No t-payment leaves escrow until the payee, the amount, and the
mandate are all proven — an autonomous verification agent stands between the
payer's funds and the recipient.*

A payer locks funds in escrow against an invoice. An autonomous verifier agent
checks the mandate before release: is the payee on the allowlist? Is the amount
within the per-agent spending limit for this window? Is the mandate signed,
unexpired, and for the stated purpose? Only a mandate that passes every check
releases funds; a failed mandate refunds the payer in full, and every decision is
logged on-chain.

### Why Agent Payments & A2A Settlement (not AI Agent Trading)

| Option | Verdict |
|---|---|
| AI Agent Trading | Needs market-making infra, price feeds, and trading capital; crowded; no security edge for this builder. |
| **Agent Payments & A2A Settlement** | **Chosen.** Direct continuation of the builder's Proof Gatekeeper / Proof-Gated Payee work (Agent Games + Aevum). The HSP payment-mandate flow is exactly the surface a security researcher should gate. No trading capital needed. |

## 3. Architecture

```
Payer (agent / user)
   │ 1. createInvoice(payee, amount, purpose, expiry) + fund escrow
   ▼
ProofGatedPayeeHSK (HSK Chain, Solidity 0.8.24)
   ├── payee registry: registerPayee / revokePayee (allowlist)
   ├── session keys: authorizeAgent (agent may ONLY release, never withdraw)
   ├── spending limits: setSpendingLimit(agent, cap, window)
   ├── views: verifyPayee / canRelease / remainingSpend
   ├── release (gated) / refund / cancelInvoice
   └── events: InvoiceCreated, Released, Refunded, PayeeRegistered/Revoked,
       AgentAuthorized, LimitSet — full on-chain audit trail
   │ 2. verifier agent checks mandate off-chain
   ▼
Verifier agent (Node/TS, off-chain) + CLI demo
   ├── reads invoice + mandate, runs the 5 gate checks
   ├── signs/releases via the authorised session key when PASS
   └── refuses + triggers refund path when FAIL (demo: unknown payee)
```

**Security model (same as the Aevum build, re-implemented fresh for HSK):**
session key can only `release`, never withdraw freely; an agent without a cap has
cap 0 and cannot release; per-invoice expiry; no owner backdoor over escrowed
funds; Checks-Effects-Interactions; custom errors.

## 4. Judging

The Seoul edition's full judging rubric could NOT be verified by text fetch
(DoraHacks page returned HTTP 405 to the crawler on 21 Nov) — **the parent must
confirm the rubric + submission form via the live browser before submit.**
Assume the standard Horizon pattern (Mumbai edition): innovation, technical
quality, real-world usefulness, demo clarity, and working on-chain deployment.
Map: the gate is the innovation; the contract + verifier + CLI is the technical
quality; A2A payments are the stated track problem; the demo shows PASS and FAIL
paths end to end.

## 5. Chain + deployment — READ FIRST, THEN BUILD

**⚠️ MAINNET FLAG (for the parent):** the Mumbai edition's rules required
"smart contracts deployed on the mainnet". The Seoul page could not be fetched,
so it is UNVERIFIED whether Seoul requires mainnet deployment at submission or
only for prize claim. **Do NOT deploy to HSK mainnet and do NOT spend real HSK
without an explicit user order.** Build + deploy to **HSK Chain testnet** first;
verify every fact below from the official HSK docs before trusting it
(chain IDs / RPCs from memory are NOT verified):
- HSK Chain is an OP-stack L2. Reported (UNVERIFIED): mainnet chain ID 177,
  testnet chain ID 133; RPCs https://mainnet.hsk.xyz / https://testnet.hsk.xyz.
- Find the official testnet faucet + block explorer from HSK docs; confirm the
  testnet chain ID + RPC by reading chain ID from the RPC (`eth_chainId`) before
  deploying.
- HSP (HashKey Settlement Protocol) API: research what it is and whether the
  payments track expects HSP mandates; if HSP needs an API key or mainnet
  access, document it and build the mandate format to match HSP's shape
  (payer, payee, amount, purpose, expiry, signature) without faking HSP itself.

## 6. Repo plan

```
dorahacks-hskchainseoul/
├── DESIGN.md            ← this file
├── README.md            ← problem, flow, setup, deploy, demo
├── LICENSE              ← MIT
├── contracts/           ← Foundry project (ProofGatedPayeeHSK.sol + tests + Deploy script)
├── agent/               ← verifier agent + CLI demo (Node/TS)
└── docs/                ← demo script, screenshots, tx hashes
```

Deliverables (per Horizon pattern): public repo + deployed contract addresses +
tx hashes + demo video (<3 min) + submission on the DoraHacks page.
Repo name (public, `rezimx-btc/`): `hsk-proof-gated-payee` (confirm at build time).

## 7. Risks + open questions

1. **Mainnet requirement unverified** — see §5. If Seoul requires mainnet at
   submission, that needs real HSK + an explicit user order; report to the
   coordinator immediately, do not improvise.
2. **HSP API unknowns** — research first; build to the mandate shape, don't fake it.
3. **Testnet faucet availability** — if no faucet works, deploy locally on anvil
   + document, and flag it.
4. **Seoul rubric / form fields** — parent to confirm via live browser.
5. **Demo Day remote slot** — finalists demo remotely; be ready 5 Dec if selected.
