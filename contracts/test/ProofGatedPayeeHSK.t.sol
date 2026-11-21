// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/ProofGatedPayeeHSK.sol";

contract ProofGatedPayeeHSKTest is Test {
    ProofGatedPayeeHSK public pg;

    address owner = address(this);
    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address stranger = makeAddr("stranger");
    address agent = makeAddr("agent");
    uint256 payerPk = 0xA11CE;
    address payerSigner;

    uint256 constant AMOUNT = 1 ether;
    string constant PURPOSE = "A2A invoice INV-2026-0001";

    function setUp() public {
        payerSigner = vm.addr(payerPk);
        pg = new ProofGatedPayeeHSK();
        vm.deal(payerSigner, 100 ether);
        vm.deal(payer, 100 ether);
        vm.deal(agent, 10 ether);
        vm.prank(owner);
        pg.registerPayee(payee, "Acme Agent Ltd");
        vm.prank(owner);
        pg.authorizeAgent(agent);
        vm.prank(owner);
        pg.setSpendingLimit(agent, 5 ether, 1 days);
    }

    // ------------------------------------------------------------ helpers
    function _invoice() internal returns (uint256 id) {
        vm.prank(payer);
        id = pg.createInvoice{value: AMOUNT}(payee, AMOUNT, PURPOSE, block.timestamp + 1 days);
    }

    function _mandate(uint256 id) internal view returns (ProofGatedPayeeHSK.Mandate memory m) {
        m = ProofGatedPayeeHSK.Mandate({
            payer: payerSigner,
            payee: payee,
            amount: AMOUNT,
            purpose: PURPOSE,
            expiry: block.timestamp + 1 days,
            invoiceId: id
        });
    }

    function _signMandate(ProofGatedPayeeHSK.Mandate memory m, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                address(pg),
                block.chainid,
                m.payer,
                m.payee,
                m.amount,
                keccak256(bytes(m.purpose)),
                m.expiry,
                m.invoiceId
            )
        );
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSigned);
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------- registry / admin
    function testOwnerIsDeployer() public view {
        assertEq(pg.owner(), owner);
    }

    function testRegisterPayee() public view {
        assertTrue(pg.isPayee(payee));
        assertEq(pg.payeeName(payee), "Acme Agent Ltd");
        assertTrue(pg.verifyPayee(payee));
        assertFalse(pg.verifyPayee(stranger));
    }

    function testRegisterPayeeOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ProofGatedPayeeHSK.NotOwner.selector);
        pg.registerPayee(stranger, "x");
    }

    function testRegisterDuplicateReverts() public {
        vm.prank(owner);
        vm.expectRevert(ProofGatedPayeeHSK.PayeeAlreadyRegistered.selector);
        pg.registerPayee(payee, "dup");
    }

    function testRevokePayeeBlocksRelease() public {
        uint256 id = _invoice();
        vm.prank(owner);
        pg.revokePayee(payee);
        assertFalse(pg.isPayee(payee));
        vm.prank(agent);
        vm.expectRevert(ProofGatedPayeeHSK.PayeeNotRegistered.selector);
        pg.release(id);
    }

    function testAuthorizeRevokeAgent() public {
        assertTrue(pg.isAgent(agent));
        vm.prank(owner);
        pg.revokeAgent(agent);
        assertFalse(pg.isAgent(agent));
        uint256 id = _invoice();
        vm.prank(agent);
        vm.expectRevert(ProofGatedPayeeHSK.NotAuthorizedAgent.selector);
        pg.release(id);
    }

    function testSetLimitOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ProofGatedPayeeHSK.NotOwner.selector);
        pg.setSpendingLimit(agent, 1 ether, 1 days);
    }

    // ------------------------------------------------------------- invoices
    function testCreateInvoice() public {
        uint256 id = _invoice();
        ProofGatedPayeeHSK.Invoice memory inv = pg.getInvoice(id);
        assertEq(inv.payer, payer);
        assertEq(inv.payee, payee);
        assertEq(inv.amount, AMOUNT);
        assertEq(inv.purpose, PURPOSE);
        assertEq(uint256(inv.status), uint256(ProofGatedPayeeHSK.InvoiceStatus.FUNDED));
        assertEq(address(pg).balance, AMOUNT);
    }

    function testCreateInvoiceUnknownPayeeReverts() public {
        vm.prank(payer);
        vm.expectRevert(ProofGatedPayeeHSK.PayeeNotRegistered.selector);
        pg.createInvoice{value: AMOUNT}(stranger, AMOUNT, PURPOSE, block.timestamp + 1 days);
    }

    function testCreateInvoiceValueMismatchReverts() public {
        vm.prank(payer);
        vm.expectRevert(ProofGatedPayeeHSK.MandateMismatch.selector);
        pg.createInvoice{value: AMOUNT - 1}(payee, AMOUNT, PURPOSE, block.timestamp + 1 days);
    }

    function testCreateInvoicePastExpiryReverts() public {
        vm.prank(payer);
        vm.expectRevert(ProofGatedPayeeHSK.MandateExpired.selector);
        pg.createInvoice{value: AMOUNT}(payee, AMOUNT, PURPOSE, block.timestamp);
    }

    function testDirectTransferReverts() public {
        vm.prank(payer);
        (bool ok,) = address(pg).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // -------------------------------------------------------------- release
    function testReleaseByAgentHappyPath() public {
        uint256 id = _invoice();
        uint256 before = payee.balance;
        vm.prank(agent);
        pg.release(id);
        assertEq(payee.balance, before + AMOUNT);
        assertEq(address(pg).balance, 0);
        assertEq(uint256(pg.getInvoice(id).status), uint256(ProofGatedPayeeHSK.InvoiceStatus.RELEASED));
        assertEq(pg.remainingSpend(agent), 5 ether - AMOUNT);
    }

    function testReleaseByPayerBypassesLimit() public {
        // Payer's own funds: no spending cap applies.
        uint256 id = _invoice();
        vm.prank(payer);
        pg.release(id);
        assertEq(payee.balance, AMOUNT);
    }

    function testReleaseByStrangerReverts() public {
        uint256 id = _invoice();
        vm.prank(stranger);
        vm.expectRevert(ProofGatedPayeeHSK.NotAuthorizedAgent.selector);
        pg.release(id);
    }

    function testDoubleReleaseReverts() public {
        uint256 id = _invoice();
        vm.prank(agent);
        pg.release(id);
        vm.prank(agent);
        vm.expectRevert(ProofGatedPayeeHSK.InvoiceNotFunded.selector);
        pg.release(id);
    }

    function testReleaseAfterExpiryReverts() public {
        uint256 id = _invoice();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(agent);
        vm.expectRevert(ProofGatedPayeeHSK.InvoiceExpired.selector);
        pg.release(id);
    }

    function testSpendingLimitEnforced() public {
        // Cap 5 ether: release 5x 1 ether, the 6th must fail.
        for (uint256 i = 0; i < 5; i++) {
            uint256 id = _invoice();
            vm.prank(agent);
            pg.release(id);
        }
        assertEq(pg.remainingSpend(agent), 0);
        uint256 lastId = _invoice();
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProofGatedPayeeHSK.SpendingLimitExceeded.selector, AMOUNT, uint256(0)
            )
        );
        pg.release(lastId);
    }

    function testSpendingWindowRollsOver() public {
        uint256 id = _invoice();
        vm.prank(agent);
        pg.release(id);
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(pg.remainingSpend(agent), 5 ether);
        uint256 id2 = _invoice();
        vm.prank(agent);
        pg.release(id2);
        assertEq(pg.remainingSpend(agent), 4 ether);
    }

    function testAgentWithNoLimitCannotRelease() public {
        address agent2 = makeAddr("agent2");
        vm.prank(owner);
        pg.authorizeAgent(agent2);
        uint256 id = _invoice();
        vm.prank(agent2);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProofGatedPayeeHSK.SpendingLimitExceeded.selector, AMOUNT, uint256(0)
            )
        );
        pg.release(id);
    }

    // ------------------------------------------------------- mandate release
    function testReleaseWithMandateHappyPath() public {
        vm.prank(payerSigner);
        uint256 id = pg.createInvoice{value: AMOUNT}(payee, AMOUNT, PURPOSE, block.timestamp + 1 days);
        ProofGatedPayeeHSK.Mandate memory m = _mandate(id);
        bytes memory sig = _signMandate(m, payerPk);
        vm.prank(agent);
        pg.releaseWithMandate(id, m, sig);
        assertEq(payee.balance, AMOUNT);
        assertEq(uint256(pg.getInvoice(id).status), uint256(ProofGatedPayeeHSK.InvoiceStatus.RELEASED));
    }

    function testReleaseWithMandateWrongSignerReverts() public {
        uint256 id = _invoice(); // invoice payer is `payer`
        ProofGatedPayeeHSK.Mandate memory m = _mandate(id); // m.payer = payerSigner
        m.payer = payer; // align mandate payer with invoice, but sig is payerSigner's
        bytes memory sig = _signMandate(m, payerPk);
        vm.prank(agent);
        vm.expectRevert(ProofGatedPayeeHSK.BadSignature.selector);
        pg.releaseWithMandate(id, m, sig);
    }

    function testReleaseWithMandateTamperedAmountReverts() public {
        vm.prank(payerSigner);
        uint256 id = pg.createInvoice{value: AMOUNT}(payee, AMOUNT, PURPOSE, block.timestamp + 1 days);
        ProofGatedPayeeHSK.Mandate memory m = _mandate(id);
        m.amount = AMOUNT + 1; // tampered after signing
        bytes memory sig = _signMandate(_mandate(id), payerPk); // sig over the true amount
        vm.prank(agent);
        vm.expectRevert(ProofGatedPayeeHSK.MandateMismatch.selector);
        pg.releaseWithMandate(id, m, sig);
    }

    function testReleaseWithMandateWrongSignatureReverts() public {
        vm.prank(payerSigner);
        uint256 id = pg.createInvoice{value: AMOUNT}(payee, AMOUNT, PURPOSE, block.timestamp + 1 days);
        ProofGatedPayeeHSK.Mandate memory m = _mandate(id);
        bytes memory sig = _signMandate(m, 0xBEEF); // signed by someone else
        vm.prank(agent);
        vm.expectRevert(ProofGatedPayeeHSK.BadSignature.selector);
        pg.releaseWithMandate(id, m, sig);
    }

    function testReleaseWithMandateShortSignatureReverts() public {
        vm.prank(payerSigner);
        uint256 id = pg.createInvoice{value: AMOUNT}(payee, AMOUNT, PURPOSE, block.timestamp + 1 days);
        ProofGatedPayeeHSK.Mandate memory m = _mandate(id);
        vm.prank(agent);
        vm.expectRevert(ProofGatedPayeeHSK.BadSignature.selector);
        pg.releaseWithMandate(id, m, hex"00");
    }

    // --------------------------------------------------------- refund/cancel
    function testRefundByPayerFull() public {
        uint256 id = _invoice();
        uint256 before = payer.balance;
        vm.prank(payer);
        pg.refund(id);
        assertEq(payer.balance, before + AMOUNT);
        assertEq(address(pg).balance, 0);
        assertEq(uint256(pg.getInvoice(id).status), uint256(ProofGatedPayeeHSK.InvoiceStatus.REFUNDED));
    }

    function testRefundByStrangerBeforeExpiryReverts() public {
        uint256 id = _invoice();
        vm.prank(stranger);
        vm.expectRevert(ProofGatedPayeeHSK.NotPayer.selector);
        pg.refund(id);
    }

    function testRefundByAnyoneAfterExpiry() public {
        uint256 id = _invoice();
        vm.warp(block.timestamp + 1 days + 1);
        uint256 before = payer.balance;
        vm.prank(stranger);
        pg.refund(id);
        assertEq(payer.balance, before + AMOUNT);
    }

    function testRefundAfterReleaseReverts() public {
        uint256 id = _invoice();
        vm.prank(agent);
        pg.release(id);
        vm.prank(payer);
        vm.expectRevert(ProofGatedPayeeHSK.InvoiceNotFunded.selector);
        pg.refund(id);
    }

    function testCancelByPayer() public {
        uint256 id = _invoice();
        uint256 before = payer.balance;
        vm.prank(payer);
        pg.cancelInvoice(id);
        assertEq(payer.balance, before + AMOUNT);
        assertEq(uint256(pg.getInvoice(id).status), uint256(ProofGatedPayeeHSK.InvoiceStatus.CANCELLED));
    }

    function testCancelByStrangerReverts() public {
        uint256 id = _invoice();
        vm.prank(stranger);
        vm.expectRevert(ProofGatedPayeeHSK.NotPayer.selector);
        pg.cancelInvoice(id);
    }

    // ---------------------------------------------------------------- views
    function testCanRelease() public {
        uint256 id = _invoice();
        (bool ok, string memory reason) = pg.canRelease(id, agent);
        assertTrue(ok);
        assertEq(reason, "ok");
        (ok, reason) = pg.canRelease(id, stranger);
        assertFalse(ok);
        assertEq(reason, "caller not authorized agent");
        (ok, reason) = pg.canRelease(999, agent);
        assertFalse(ok);
        assertEq(reason, "invoice not found");
    }

    function testCanReleaseUnknownPayeeAfterRevoke() public {
        uint256 id = _invoice();
        vm.prank(owner);
        pg.revokePayee(payee);
        (bool ok, string memory reason) = pg.canRelease(id, agent);
        assertFalse(ok);
        assertEq(reason, "payee not registered");
    }

    function testGetInvoiceNotFoundReverts() public {
        vm.expectRevert(ProofGatedPayeeHSK.InvoiceNotFound.selector);
        pg.getInvoice(999);
    }

    // ------------------------------------------- no owner backdoor on escrow
    function testOwnerCannotDrainEscrow() public {
        // There is no withdraw/sweep function: the only exits are release
        // (to the registered payee) and refund/cancel (to the payer).
        // Owner attempting release as a non-agent, non-payer must fail.
        uint256 id = _invoice();
        vm.prank(owner);
        vm.expectRevert(ProofGatedPayeeHSK.NotAuthorizedAgent.selector);
        pg.release(id);
        // Owner cannot refund someone else's invoice before expiry either.
        vm.prank(owner);
        vm.expectRevert(ProofGatedPayeeHSK.NotPayer.selector);
        pg.refund(id);
        assertEq(address(pg).balance, AMOUNT);
    }
}
