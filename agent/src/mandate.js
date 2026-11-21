// HSP-shaped payment mandate.
// Shape mirrors the HashKey Settlement Protocol (HSP) Cart Mandate as
// described in HashKey's public material: payer, payee, amount, purpose,
// expiry + payer signature. This code does NOT call any HSP service and does
// not fake one — HSP has no public developer API/key flow we could verify
// (see README §HSP). The mandate is the payer's own EIP-191 signature over
// the mandate fields, verified on-chain by ProofGatedPayeeHSK.
import { ethers } from "ethers";

/** Build the exact digest the contract verifies (must match _recoverSigner). */
export function mandateDigest(contractAddress, chainId, m) {
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "uint256", "address", "address", "uint256", "bytes32", "uint256", "uint256"],
    [
      contractAddress,
      chainId,
      m.payer,
      m.payee,
      m.amount,
      ethers.keccak256(ethers.toUtf8Bytes(m.purpose)),
      m.expiry,
      m.invoiceId,
    ],
  );
  return ethers.keccak256(encoded);
}

/** Payer signs the mandate (EIP-191 personal sign, same as the contract). */
export async function signMandate(signerWallet, contractAddress, chainId, m) {
  const digest = mandateDigest(contractAddress, chainId, m);
  return signerWallet.signMessage(ethers.getBytes(digest));
}

/** Off-chain recovery: who signed this mandate? */
export function recoverMandateSigner(contractAddress, chainId, m, signature) {
  const digest = mandateDigest(contractAddress, chainId, m);
  return ethers.verifyMessage(ethers.getBytes(digest), signature);
}

export function toMandateTuple(m) {
  return [m.payer, m.payee, m.amount, m.purpose, m.expiry, m.invoiceId];
}
