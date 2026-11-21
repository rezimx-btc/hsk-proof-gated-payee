// Autonomous verifier agent: the 5 gate checks from DESIGN.md §3.
// The agent stands between the payer's escrowed funds and the recipient:
// it only calls release when EVERY check passes; otherwise it refuses and
// the demo triggers the full-refund path.
import { ethers } from "ethers";
import { recoverMandateSigner } from "./mandate.js";

export const CHECKS = [
  "1-payee-allowlisted",
  "2-amount-within-spending-limit",
  "3-mandate-signature-valid",
  "4-mandate-unexpired",
  "5-purpose-matches-invoice",
];

/**
 * Run all 5 gates for an invoice + mandate, as the releasing agent would.
 * @returns {{ pass: boolean, results: Array<{check: string, pass: boolean, detail: string}> }}
 */
export async function verifyMandate(contract, agentAddress, invoiceId, mandate, signature) {
  const results = [];
  const fail = (check, detail) => ({ check, pass: false, detail });
  const ok = (check, detail) => ({ check, pass: true, detail });

  const inv = await contract.getInvoice(invoiceId);
  const now = Math.floor(Date.now() / 1000);

  // Gate 1 — payee on the allowlist?
  const listed = await contract.verifyPayee(inv.payee);
  results.push(
    listed
      ? ok(CHECKS[0], `payee ${inv.payee} is registered`)
      : fail(CHECKS[0], `payee ${inv.payee} is NOT on the allowlist`),
  );

  // Gate 2 — amount within the agent's remaining spend for this window?
  const remaining = await contract.remainingSpend(agentAddress);
  results.push(
    BigInt(inv.amount) <= remaining
      ? ok(CHECKS[1], `amount ${ethers.formatEther(inv.amount)} <= remaining ${ethers.formatEther(remaining)}`)
      : fail(CHECKS[1], `amount ${ethers.formatEther(inv.amount)} > remaining ${ethers.formatEther(remaining)}`),
  );

  // Gate 3 — mandate signature recovers to the invoice payer?
  let signer = ethers.ZeroAddress;
  let sigOk = false;
  try {
    const chainId = (await contract.runner.provider.getNetwork()).chainId;
    signer = recoverMandateSigner(await contract.getAddress(), chainId, mandate, signature);
    sigOk = signer.toLowerCase() === inv.payer.toLowerCase();
  } catch (e) {
    sigOk = false;
  }
  results.push(
    sigOk
      ? ok(CHECKS[2], `mandate signed by payer ${signer}`)
      : fail(CHECKS[2], `mandate signature recovers to ${signer}, expected payer ${inv.payer}`),
  );

  // Gate 4 — mandate / invoice unexpired?
  const unexpired = Number(mandate.expiry) > now && Number(inv.expiry) > now;
  results.push(
    unexpired
      ? ok(CHECKS[3], `expiry ${new Date(Number(inv.expiry) * 1000).toISOString()} is in the future`)
      : fail(CHECKS[3], `invoice/mandate expired at ${new Date(Number(inv.expiry) * 1000).toISOString()}`),
  );

  // Gate 5 — purpose matches the invoice?
  const purposeOk = mandate.purpose === inv.purpose;
  results.push(
    purposeOk
      ? ok(CHECKS[4], `purpose matches: "${inv.purpose}"`)
      : fail(CHECKS[4], `mandate purpose "${mandate.purpose}" != invoice purpose "${inv.purpose}"`),
  );

  // Belt & braces: ask the contract itself whether release would succeed.
  const [can, reason] = await contract.canRelease(invoiceId, agentAddress);
  if (!can) results.push(fail("6-contract-canRelease", `contract says: ${reason}`));

  return { pass: results.every((r) => r.pass), results };
}

export function printVerdict(title, verdict) {
  console.log(`\n--- ${title} ---`);
  for (const r of verdict.results) {
    console.log(`  ${r.pass ? "PASS" : "FAIL"}  ${r.check} — ${r.detail}`);
  }
  console.log(`  ==> VERDICT: ${verdict.pass ? "PASS — release allowed" : "FAIL — release refused"}`);
  return verdict.pass;
}
