// Proof-Gated Payee — CLI demo (HSK Chain).
//   node src/cli.mjs demo [--network anvil|testnet]
// Anvil (default): self-contained local demo — spawns anvil, deploys a fresh
// contract, runs the PASS flow then the FAIL flows, prints tx hashes.
// Testnet: needs CONTRACT_ADDRESS + PAYER_PRIVATE_KEY + AGENT_PRIVATE_KEY
// (TESTNET-ONLY keys) in env or agent/.env — never mainnet keys.
import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { ethers } from "ethers";
import { ABI } from "./abi.js";
import { signMandate, toMandateTuple } from "./mandate.js";
import { verifyMandate, printVerdict } from "./verifier.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..", "..");
const ANVIL_RPC = "http://127.0.0.1:8545";
const TESTNET_RPC = "https://testnet.hsk.xyz";
const EXPLORER = "https://testnet-explorer.hskchain.net";

// Well-known anvil test accounts (local demo ONLY — no value anywhere).
const ANVIL_KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // payer / owner
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // agent (session key)
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // payee
];

const PURPOSE = "A2A invoice INV-2026-0001";
// Testnet demo funds are scarce (faucet paid 0.1 tHSK, not 1) — allow a
// smaller amount via DEMO_AMOUNT_ETH; default stays 1 ETH (anvil).
const AMOUNT = ethers.parseEther(process.env.DEMO_AMOUNT_ETH || "1");
const SPEND_CAP = ethers.parseEther("5");
const WINDOW = 86400; // 1 day

function log(...a) {
  console.log(...a);
}

async function rpcUp(url) {
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      signal: AbortSignal.timeout(3000),
    });
    return r.ok;
  } catch {
    return false;
  }
}

async function ensureAnvil() {
  if (await rpcUp(ANVIL_RPC)) return null;
  log("anvil not running — starting local anvil…");
  const anvil = spawn("anvil", ["--port", "8545"], {
    stdio: "ignore",
    env: { ...process.env, PATH: `${process.env.HOME}/.foundry/bin:${process.env.PATH}` },
  });
  for (let i = 0; i < 30; i++) {
    if (await rpcUp(ANVIL_RPC)) return anvil;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("anvil did not come up");
}

function loadArtifact() {
  const p = path.join(ROOT, "contracts", "out", "ProofGatedPayeeHSK.sol", "ProofGatedPayeeHSK.json");
  if (!existsSync(p)) {
    throw new Error(`compiled artifact missing: ${p} — run "forge build" in contracts/ first`);
  }
  return JSON.parse(readFileSync(p, "utf8"));
}

let anvilProc = null;

async function demo() {
  const args = process.argv.slice(3);
  const network = args.includes("--network") ? args[args.indexOf("--network") + 1] : "anvil";
  const isTestnet = network === "testnet";
  if (isTestnet) log("NETWORK: HSK Chain TESTNET (chain ID 133) — no mainnet, ever.");
  else log("NETWORK: local anvil (chain ID 31337) — demo only.");

  let provider;
  let payer, agent, payee, payerTx, agentTx;
  let contract;

  if (isTestnet) {
    provider = new ethers.JsonRpcProvider(TESTNET_RPC);
    const chainId = (await provider.getNetwork()).chainId;
    if (chainId !== 133n) throw new Error(`expected HSK testnet 133, got ${chainId}`);
    const addr = process.env.CONTRACT_ADDRESS;
    if (!addr) throw new Error("set CONTRACT_ADDRESS env (testnet deployment)");
    if (!process.env.PAYER_PRIVATE_KEY || !process.env.AGENT_PRIVATE_KEY) {
      throw new Error("set PAYER_PRIVATE_KEY + AGENT_PRIVATE_KEY env (TESTNET-ONLY keys)");
    }
    payer = new ethers.Wallet(process.env.PAYER_PRIVATE_KEY, provider);
    agent = new ethers.Wallet(process.env.AGENT_PRIVATE_KEY, provider);
    payee = { address: process.env.PAYEE_ADDRESS || payer.address };
    // NonceManager serializes nonces locally — no provider nonce-query race.
    payerTx = new ethers.NonceManager(payer);
    agentTx = new ethers.NonceManager(agent);
    contract = new ethers.Contract(addr, ABI, provider);
    log(`contract: ${addr}`);
    log(`explorer: ${EXPLORER}/address/${addr}`);
  } else {
    anvilProc = await ensureAnvil();
    provider = new ethers.JsonRpcProvider(ANVIL_RPC);
    payer = new ethers.Wallet(ANVIL_KEYS[0], provider);
    agent = new ethers.Wallet(ANVIL_KEYS[1], provider);
    payee = new ethers.Wallet(ANVIL_KEYS[2], provider);
    // NonceManager serializes nonces locally — no provider nonce-query race.
    payerTx = new ethers.NonceManager(payer);
    agentTx = new ethers.NonceManager(agent);
    const artifact = loadArtifact();
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object, payer);
    log("deploying ProofGatedPayeeHSK to anvil…");
    contract = await factory.deploy();
    await contract.waitForDeployment();
    const addr = await contract.getAddress();
    log(`deployed at: ${addr}`);
    log(`owner: ${await contract.owner()}`);
    // Setup: registry + session key + spending limit.
    log("setup: registerPayee + authorizeAgent + setSpendingLimit(5 ETH / 1 day)…");
    await (await contract.connect(payerTx).registerPayee(payee.address, "Acme Agent Ltd")).wait();
    await (await contract.connect(payerTx).authorizeAgent(agent.address)).wait();
    await (await contract.connect(payerTx).setSpendingLimit(agent.address, SPEND_CAP, WINDOW)).wait();
  }

  const chainId = (await provider.getNetwork()).chainId;
  const cAddr = await contract.getAddress();
  const asPayer = contract.connect(payerTx);
  const asAgent = contract.connect(agentTx);
  const now = () => Math.floor(Date.now() / 1000);

  // ============================================================ PASS FLOW
  log("\n================ FLOW 1 — PASS: mandate valid, funds released ================");
  const expiry = now() + 86400;
  const payeeBefore = await provider.getBalance(payee.address);
  const txCreate = await asPayer.createInvoice(payee.address, AMOUNT, PURPOSE, expiry, { value: AMOUNT });
  const rcCreate = await txCreate.wait();
  const invoiceId = Number(await contract.nextInvoiceId()) - 1;
  log(`invoice #${invoiceId} created + funded ${ethers.formatEther(AMOUNT)} ETH — tx ${rcCreate.hash}`);
  const mandate = { payer: payer.address, payee: payee.address, amount: AMOUNT, purpose: PURPOSE, expiry, invoiceId };
  const sig = await signMandate(payer, cAddr, chainId, mandate);
  log(`mandate signed by payer ${payer.address}`);
  const v1 = await verifyMandate(contract, agent.address, invoiceId, mandate, sig);
  printVerdict("verifier — 5 gates", v1);
  if (!v1.pass) throw new Error("PASS flow unexpectedly failed verification");
  const txRel = await asAgent.releaseWithMandate(invoiceId, toMandateTuple(mandate), sig);
  const rcRel = await txRel.wait();
  // Read the balance AT the release block: ethers caches "latest" reads and
  // can return the pre-tx value when calls land in the same polling window.
  const payeeAfter = await provider.getBalance(payee.address, rcRel.blockNumber);
  log(`RELEASED — payee +${ethers.formatEther(payeeAfter - payeeBefore)} ETH — tx ${rcRel.hash}`);
  log(`contract balance now: ${ethers.formatEther(await provider.getBalance(cAddr))} ETH`);

  // ================================================ FAIL FLOW A — unknown payee
  log("\n================ FLOW 2 — FAIL: payee revoked (unknown) → refund penuh ================");
  const txCreate2 = await asPayer.createInvoice(payee.address, AMOUNT, PURPOSE, now() + 86400, { value: AMOUNT });
  await txCreate2.wait();
  const id2 = Number(await contract.nextInvoiceId()) - 1;
  log(`invoice #${id2} created + funded ${ethers.formatEther(AMOUNT)} ETH`);
  await (await asPayer.revokePayee(payee.address)).wait();
  log(`payee ${payee.address} REVOKED from allowlist`);
  const mandate2 = { payer: payer.address, payee: payee.address, amount: AMOUNT, purpose: PURPOSE, expiry: now() + 86400, invoiceId: id2 };
  const sig2 = await signMandate(payer, cAddr, chainId, mandate2);
  const v2 = await verifyMandate(contract, agent.address, id2, mandate2, sig2);
  printVerdict("verifier — 5 gates", v2);
  try {
    await asAgent.release(id2);
    throw new Error("release should have reverted for unknown payee");
  } catch (e) {
    log(`release correctly REVERTED: ${(e.shortMessage || e.message).split("\n")[0]}`);
  }
  const payerBefore = await provider.getBalance(payer.address);
  const txRef = await asPayer.refund(id2);
  const rcRef = await txRef.wait();
  // Balance AT the refund block (see Flow 1 note on cached "latest" reads).
  const payerAfter = await provider.getBalance(payer.address, rcRef.blockNumber);
  log(`REFUNDED in full — payer balance +${ethers.formatEther(payerAfter - payerBefore)} ETH (net of gas) — tx ${rcRef.hash}`);
  log(`contract balance now: ${ethers.formatEther(await provider.getBalance(cAddr))} ETH`);
  await (await asPayer.registerPayee(payee.address, "Acme Agent Ltd")).wait();
  log("payee re-registered for the next flow");

  // ============================================= FAIL FLOW B — tampered mandate
  log("\n================ FLOW 3 — FAIL: mandate dipalsu (amount diubah) → refund penuh ================");
  const txCreate3 = await asPayer.createInvoice(payee.address, AMOUNT, PURPOSE, now() + 86400, { value: AMOUNT });
  await txCreate3.wait();
  const id3 = Number(await contract.nextInvoiceId()) - 1;
  const mandate3 = { payer: payer.address, payee: payee.address, amount: AMOUNT, purpose: PURPOSE, expiry: now() + 86400, invoiceId: id3 };
  const sig3 = await signMandate(payer, cAddr, chainId, mandate3);
  const tampered = { ...mandate3, amount: ethers.parseEther("2") }; // attacker doubles the amount
  log(`mandate amount tampered: ${ethers.formatEther(AMOUNT)} ETH -> ${ethers.formatEther(AMOUNT * 2n)} ETH (signature NOT re-signed)`);
  const v3 = await verifyMandate(contract, agent.address, id3, tampered, sig3);
  printVerdict("verifier — 5 gates", v3);
  try {
    await asAgent.releaseWithMandate(id3, toMandateTuple(tampered), sig3);
    throw new Error("tampered release should have reverted");
  } catch (e) {
    log(`release correctly REVERTED: ${(e.shortMessage || e.message).split("\n")[0]}`);
  }
  const txRef3 = await asPayer.refund(id3);
  const rcRef3 = await txRef3.wait();
  log(`REFUNDED in full — tx ${rcRef3.hash}`);
  log(`contract balance now: ${ethers.formatEther(await provider.getBalance(cAddr))} ETH`);

  log("\n================ DEMO COMPLETE ================");
  log("PASS flow: mandate valid -> released to registered payee.");
  log("FAIL flow A: payee unknown -> release refused -> payer refunded in full.");
  log("FAIL flow B: mandate tampered -> release refused -> payer refunded in full.");
  if (anvilProc) anvilProc.kill();
}

demo().catch((e) => {
  console.error("DEMO FAILED:", e.shortMessage || e.message);
  console.error(e.stack);
  if (anvilProc) anvilProc.kill();
  process.exit(1);
});
