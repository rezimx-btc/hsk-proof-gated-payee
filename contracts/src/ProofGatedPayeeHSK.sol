// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ProofGatedPayeeHSK
/// @notice Proof-gated escrow for agent-to-agent (A2A) payments on HSK Chain.
/// @dev A payer locks funds against an invoice. Funds leave escrow ONLY when
///      (1) the payee is on the allowlist, (2) the amount fits the releasing
///      agent's spending limit for the current window, (3) the payer-signed
///      HSP-shaped mandate (payer, payee, amount, purpose, expiry, invoiceId,
///      chainId, contract) verifies on-chain, and (4) the invoice has not
///      expired. A failed mandate never releases: the payer is refunded in
///      full. The owner administers ONLY the registry, session keys and
///      limits — there is NO owner backdoor over escrowed funds: no function
///      lets anyone (owner included) move escrowed funds except `release`
///      (to the registered payee) and `refund`/`cancelInvoice` (to the payer).
///      Checks-Effects-Interactions + a reentrancy lock throughout.
contract ProofGatedPayeeHSK {
    // ---------------------------------------------------------------- errors
    error NotOwner();
    error NotPayer();
    error NotAuthorizedAgent();
    error ZeroAddress();
    error ZeroAmount();
    error PayeeNotRegistered();
    error PayeeAlreadyRegistered();
    error AgentAlreadyAuthorized();
    error AgentNotAuthorized();
    error InvoiceNotFound();
    error InvoiceNotFunded();
    error InvoiceExpired();
    error InvoiceNotExpired();
    error MandateExpired();
    error MandateMismatch();
    error BadSignature();
    error SpendingLimitExceeded(uint256 requested, uint256 remaining);
    error TransferFailed();
    error Reentrant();

    // ---------------------------------------------------------------- events
    event PayeeRegistered(address indexed payee, string name);
    event PayeeRevoked(address indexed payee);
    event AgentAuthorized(address indexed agent);
    event AgentRevoked(address indexed agent);
    event LimitSet(address indexed agent, uint256 cap, uint256 windowSeconds);
    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        string purpose,
        uint256 expiry
    );
    event Released(uint256 indexed invoiceId, address indexed payee, uint256 amount, address indexed agent);
    event Refunded(uint256 indexed invoiceId, address indexed payer, uint256 amount);
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed payer, uint256 amount);

    // ---------------------------------------------------------------- types
    enum InvoiceStatus {
        FUNDED,
        RELEASED,
        REFUNDED,
        CANCELLED
    }

    struct Invoice {
        address payer;
        address payee;
        uint256 amount;
        string purpose;
        uint256 expiry;
        InvoiceStatus status;
    }

    /// @notice HSP-shaped payment mandate, signed off-chain by the payer.
    /// @dev Mirrors the HashKey Settlement Protocol Cart Mandate shape
    ///      (payer, payee, amount, purpose, expiry + signature). This
    ///      contract does NOT call any HSP service and does not fake one:
    ///      it verifies the payer's own signature over the mandate fields.
    struct Mandate {
        address payer;
        address payee;
        uint256 amount;
        string purpose;
        uint256 expiry;
        uint256 invoiceId;
    }

    struct SpendingLimit {
        uint256 cap; // max releasable per window (0 = no releases)
        uint256 windowSeconds; // window length, 0 = no window configured
        uint256 windowStart; // start of the current window
        uint256 spent; // spent inside the current window
    }

    // ---------------------------------------------------------------- state
    address public immutable owner;
    uint256 public nextInvoiceId;
    mapping(uint256 => Invoice) public invoices;
    mapping(address => bool) public isPayee;
    mapping(address => string) public payeeName;
    mapping(address => bool) public isAgent;
    mapping(address => SpendingLimit) public limits;

    bool private _locked;

    // ------------------------------------------------------------- modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    constructor() {
        owner = msg.sender;
    }

    // ------------------------------------------------------- payee registry
    function registerPayee(address payee, string calldata name) external onlyOwner {
        if (payee == address(0)) revert ZeroAddress();
        if (isPayee[payee]) revert PayeeAlreadyRegistered();
        isPayee[payee] = true;
        payeeName[payee] = name;
        emit PayeeRegistered(payee, name);
    }

    function revokePayee(address payee) external onlyOwner {
        if (!isPayee[payee]) revert PayeeNotRegistered();
        isPayee[payee] = false;
        delete payeeName[payee];
        emit PayeeRevoked(payee);
    }

    // --------------------------------------------------------- session keys
    /// @notice Authorize an agent session key. The agent may ONLY call
    ///         `release`/`releaseWithMandate` — it can never withdraw.
    function authorizeAgent(address agent) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        if (isAgent[agent]) revert AgentAlreadyAuthorized();
        isAgent[agent] = true;
        emit AgentAuthorized(agent);
    }

    function revokeAgent(address agent) external onlyOwner {
        if (!isAgent[agent]) revert AgentNotAuthorized();
        isAgent[agent] = false;
        emit AgentRevoked(agent);
    }

    // ------------------------------------------------------- spending limits
    function setSpendingLimit(address agent, uint256 cap, uint256 windowSeconds) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        SpendingLimit storage l = limits[agent];
        l.cap = cap;
        l.windowSeconds = windowSeconds;
        // A limit change starts a fresh window.
        l.windowStart = block.timestamp;
        l.spent = 0;
        emit LimitSet(agent, cap, windowSeconds);
    }

    // -------------------------------------------------------------- invoices
    function createInvoice(address payee, uint256 amount, string calldata purpose, uint256 expiry)
        external
        payable
        returns (uint256 invoiceId)
    {
        if (payee == address(0)) revert ZeroAddress();
        if (!isPayee[payee]) revert PayeeNotRegistered();
        if (amount == 0) revert ZeroAmount();
        if (msg.value != amount) revert MandateMismatch(); // value must equal the invoiced amount
        if (expiry <= block.timestamp) revert MandateExpired();

        invoiceId = nextInvoiceId++;
        invoices[invoiceId] = Invoice({
            payer: msg.sender,
            payee: payee,
            amount: amount,
            purpose: purpose,
            expiry: expiry,
            status: InvoiceStatus.FUNDED
        });
        emit InvoiceCreated(invoiceId, msg.sender, payee, amount, purpose, expiry);
    }

    /// @notice Release escrowed funds to the registered payee.
    /// @dev Callable by the payer (their own funds, no spending cap) or by
    ///      an authorized agent session key (capped by its spending limit).
    function release(uint256 invoiceId) external nonReentrant {
        _release(invoiceId, msg.sender);
    }

    /// @notice Release gated by a payer-signed HSP-shaped mandate.
    /// @dev The mandate must match the invoice field-for-field and its
    ///      EIP-191 signature must recover to the invoice payer.
    function releaseWithMandate(uint256 invoiceId, Mandate calldata m, bytes calldata signature)
        external
        nonReentrant
    {
        Invoice storage inv = invoices[invoiceId];
        if (inv.payer == address(0)) revert InvoiceNotFound();
        if (m.invoiceId != invoiceId) revert MandateMismatch();
        if (m.payer != inv.payer) revert MandateMismatch();
        if (m.payee != inv.payee) revert MandateMismatch();
        if (m.amount != inv.amount) revert MandateMismatch();
        if (keccak256(bytes(m.purpose)) != keccak256(bytes(inv.purpose))) revert MandateMismatch();
        if (m.expiry != inv.expiry) revert MandateMismatch();
        if (m.expiry <= block.timestamp) revert MandateExpired();
        if (_recoverSigner(m, signature) != inv.payer) revert BadSignature();
        _release(invoiceId, msg.sender);
    }

    function _release(uint256 invoiceId, address caller) internal {
        Invoice storage inv = invoices[invoiceId];
        if (inv.payer == address(0)) revert InvoiceNotFound();
        if (inv.status != InvoiceStatus.FUNDED) revert InvoiceNotFunded();
        if (block.timestamp > inv.expiry) revert InvoiceExpired();
        if (!isPayee[inv.payee]) revert PayeeNotRegistered();

        if (caller != inv.payer) {
            if (!isAgent[caller]) revert NotAuthorizedAgent();
            _chargeLimit(caller, inv.amount);
        }

        inv.status = InvoiceStatus.RELEASED;
        emit Released(invoiceId, inv.payee, inv.amount, caller);
        (bool ok,) = payable(inv.payee).call{value: inv.amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Refund the payer in full. Callable by the payer any time
    ///         while FUNDED, or by anyone once the invoice has expired.
    function refund(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.payer == address(0)) revert InvoiceNotFound();
        if (inv.status != InvoiceStatus.FUNDED) revert InvoiceNotFunded();
        if (msg.sender != inv.payer && block.timestamp <= inv.expiry) revert NotPayer();

        inv.status = InvoiceStatus.REFUNDED;
        emit Refunded(invoiceId, inv.payer, inv.amount);
        (bool ok,) = payable(inv.payer).call{value: inv.amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Cancel a FUNDED invoice; funds return to the payer in full.
    function cancelInvoice(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.payer == address(0)) revert InvoiceNotFound();
        if (msg.sender != inv.payer) revert NotPayer();
        if (inv.status != InvoiceStatus.FUNDED) revert InvoiceNotFunded();

        inv.status = InvoiceStatus.CANCELLED;
        emit InvoiceCancelled(invoiceId, inv.payer, inv.amount);
        (bool ok,) = payable(inv.payer).call{value: inv.amount}("");
        if (!ok) revert TransferFailed();
    }

    // ----------------------------------------------------------------- views
    function verifyPayee(address payee) external view returns (bool) {
        return isPayee[payee];
    }

    /// @notice Remaining spend for an agent in its current window.
    function remainingSpend(address agent) public view returns (uint256) {
        SpendingLimit storage l = limits[agent];
        if (l.windowSeconds == 0) return 0;
        if (block.timestamp >= l.windowStart + l.windowSeconds) return l.cap; // window rolled over
        if (l.spent >= l.cap) return 0;
        return l.cap - l.spent;
    }

    /// @notice Full gate preview: would `release` succeed right now?
    function canRelease(uint256 invoiceId, address caller) external view returns (bool ok, string memory reason) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.payer == address(0)) return (false, "invoice not found");
        if (inv.status != InvoiceStatus.FUNDED) return (false, "invoice not funded");
        if (block.timestamp > inv.expiry) return (false, "invoice expired");
        if (!isPayee[inv.payee]) return (false, "payee not registered");
        if (caller != inv.payer) {
            if (!isAgent[caller]) return (false, "caller not authorized agent");
            if (remainingSpend(caller) < inv.amount) return (false, "spending limit exceeded");
        }
        return (true, "ok");
    }

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        if (invoices[invoiceId].payer == address(0)) revert InvoiceNotFound();
        return invoices[invoiceId];
    }

    // -------------------------------------------------------------- internal
    function _chargeLimit(address agent, uint256 amount) internal {
        SpendingLimit storage l = limits[agent];
        if (l.windowSeconds == 0) revert SpendingLimitExceeded(amount, 0);
        if (block.timestamp >= l.windowStart + l.windowSeconds) {
            l.windowStart = block.timestamp;
            l.spent = 0;
        }
        uint256 remaining = l.cap > l.spent ? l.cap - l.spent : 0;
        if (amount > remaining) revert SpendingLimitExceeded(amount, remaining);
        l.spent += amount;
    }

    /// @notice EIP-191 personal-sign recovery over the mandate digest.
    function _recoverSigner(Mandate calldata m, bytes calldata signature) internal view returns (address) {
        bytes32 digest = keccak256(
            abi.encode(
                address(this),
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
        (bytes32 r, bytes32 s, uint8 v) = _split(signature);
        return ecrecover(ethSigned, v, r, s);
    }

    function _split(bytes calldata sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        if (sig.length != 65) revert BadSignature();
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
    }

    // Reject plain transfers: funds may only enter via createInvoice.
    receive() external payable {
        revert MandateMismatch();
    }
}
