// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ERC20 Escrow Contract
/// @author Olugbenga Ayoola
/// @notice A trustless escrow system for ERC20 tokens with mediation support
/// @dev Seller creates escrow, buyer funds it. 1% platform fee on all outcomes.
///      Both parties must confirm the same outcome for auto-execution.
///      Owner mediates after escrow expiry if parties disagree or go silent.
contract Escrow {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────
    //  CONSTANTS
    // ─────────────────────────────────────────────

    /// @notice Platform fee in basis points (1% = 100 bps)
    uint256 public constant FEE_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Window within which buyer must fund after escrow creation else escrow becomes cancelled
    uint256 public constant FUNDING_WINDOW = 24 hours;

    // ─────────────────────────────────────────────
    //  IMMUTABLES
    // ─────────────────────────────────────────────

    /// @notice Maximum allowed escrow duration, set at deployment
    uint256 public immutable MAX_DURATION;

    /// @notice Contract owner and mediator
    address public immutable OWNER;

    // ─────────────────────────────────────────────
    //  TYPES
    // ─────────────────────────────────────────────

    enum EscrowState {
        CREATED,
        FUNDED,
        RELEASED,
        REFUNDED,
        CANCELLED
    }

    enum Confirmation {
        NONE,
        RELEASE,
        REFUND
    }

    struct EscrowData {
        address seller;
        address buyer;
        address token;
        uint256 amount; // escrow amount deposited by buyer
        uint256 createdAt; // timestamp of creation
        uint256 expiresAt; // timestamp when escrow expires
        EscrowState state;
        Confirmation sellerConfirmation; //seller's confirmation to release or refund
        Confirmation buyerConfirmation; //buyer's confirmation to release or refund
        bytes data; // additional data field for escrow metadata (e.g. IPFS hash of off-chain agreement)
    }

    // ─────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────

    /// @notice Whitelisted ERC20 tokens allowed in escrow
    mapping(address => bool) public allowedTokens;

    /// @notice Accumulated platform fees per token. Tracked so owner can't withdraw escrow funds.
    mapping(address => uint256) public accumulatedFees;

    /// @notice All escrows by ID
    mapping(uint256 => EscrowData) internal escrows;

    /// @notice Escrow ID counter
    uint256 public nextEscrowId;

    // ─────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────

    event TokenAllowed(address indexed token, bool indexed allowed);
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed seller,
        address indexed buyer,
        address token,
        uint256 amount,
        uint256 expiresAt,
        bytes data
    );
    event EscrowFunded(uint256 indexed escrowId, address indexed buyer, uint256 indexed amount, address token);
    event EscrowCancelled(uint256 indexed escrowId, address indexed cancelledBy);
    event ConfirmationSubmitted(uint256 indexed escrowId, address indexed party, Confirmation indexed confirmation);
    event EscrowReleased(uint256 indexed escrowId, address indexed seller, uint256 indexed amount, address token);
    event EscrowRefunded(uint256 indexed escrowId, address indexed buyer, uint256 indexed amount, address token);
    event MediatorResolved(uint256 indexed escrowId, Confirmation indexed resolution);
    event FeesWithdrawn(address indexed token, uint256 indexed amount);

    // ─────────────────────────────────────────────
    //  ERRORS
    // ─────────────────────────────────────────────

    error NotOwner();
    error NotBuyer();
    error NotParticipant();
    error TokenNotAllowed(address token);
    error ZeroAmount();
    error ZeroAddress();
    error InvalidDuration();
    error EscrowNotFound(uint256 escrowId);
    error InvalidConfirmation(Confirmation confirmation);
    error FundingWindowNotExpired(uint256 escrowId);
    error FundingWindowExpired(uint256 escrowId);
    error EscrowNotExpired(uint256 escrowId);
    error EscrowExpired(uint256 escrowId);
    error AlreadyConfirmed(Confirmation confirmation);
    error NoFeesToWithdraw(uint256 amount);
    error BuyerCannotBeSeller();
    error TokenAlreadySet(address token, bool allowed);
    error InvalidState(EscrowState current, EscrowState expected);

    // ─────────────────────────────────────────────
    //  MODIFIERS
    // ─────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    modifier onlyBuyer(uint256 escrowId) {
        if (msg.sender != escrows[escrowId].buyer) revert NotBuyer();
        _;
    }

    modifier inState(uint256 escrowId, EscrowState expected) {
        EscrowData storage escrow = escrows[escrowId];
        if (escrow.seller == address(0)) revert EscrowNotFound(escrowId); // check escrow existence first
        EscrowState current = escrow.state;
        if (current != expected) revert InvalidState(current, expected);
        _;
    }

    // ─────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────

    /// @param _maxDuration Maximum duration in seconds for any escrow
    /// @param _allowedTokens Initial list of whitelisted tokens
    constructor(uint256 _maxDuration, address[] memory _allowedTokens) {
        if (_maxDuration == 0) revert InvalidDuration();
        OWNER = msg.sender;
        MAX_DURATION = _maxDuration;
        uint256 len = _allowedTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = _allowedTokens[i];
            if (token == address(0)) revert ZeroAddress();
            allowedTokens[token] = true;
            emit TokenAllowed(token, true);
        }
    }

    // ─────────────────────────────────────────────
    //  OWNER FUNCTIONS
    // ─────────────────────────────────────────────

    /// @notice Add or remove a token from the whitelist
    /// @param token Token address to update
    /// @param allowed True to allow, false to disallow
    function setAllowedToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (allowedTokens[token] == allowed) revert TokenAlreadySet(token, allowed);
        allowedTokens[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    /// @notice Withdraw accumulated platform fees for a specific token
    /// @param token Token address to withdraw fees for
    /// @param amount Amount to withdraw (must be <= accumulated fees)
    function withdrawFees(address token, uint256 amount) external onlyOwner {
        if (amount == 0) revert NoFeesToWithdraw(amount);
        accumulatedFees[token] -= amount; // reverts if amount > accumulatedFees[token]
        IERC20(token).safeTransfer(OWNER, amount);
        emit FeesWithdrawn(token, amount);
    }

    /// @notice Mediator resolves an expired escrow that parties couldn't settle
    /// @param escrowId The escrow to resolve
    /// @param resolution RELEASE sends funds to seller, REFUND sends to buyer
    function mediate(uint256 escrowId, Confirmation resolution)
        external
        onlyOwner
        inState(escrowId, EscrowState.FUNDED)
    {
        EscrowData storage escrow = escrows[escrowId];
        if (block.timestamp <= escrow.expiresAt) revert EscrowNotExpired(escrowId);
        if (resolution == Confirmation.NONE) revert InvalidConfirmation(resolution);

        emit MediatorResolved(escrowId, resolution);
        _finalize(escrowId, escrow, resolution);
    }

    // ─────────────────────────────────────────────
    //  SELLER FUNCTIONS
    // ─────────────────────────────────────────────

    /// @notice Seller creates a new escrow
    /// @param buyer Address of the buyer
    /// @param token ERC20 token to be used
    /// @param amount Gross amount buyer will deposit
    /// @param duration Duration in seconds. Must be > FUNDING_WINDOW (24h) and <= MAX_DURATION.
    /// @param data Additional metadata for the escrow
    /// @return escrowId The ID of the newly created escrow
    function createEscrow(address buyer, address token, uint256 amount, uint256 duration, bytes calldata data)
        external
        returns (uint256 escrowId)
    {
        if (buyer == address(0)) revert ZeroAddress();
        if (buyer == msg.sender) revert BuyerCannotBeSeller();
        if (!allowedTokens[token]) revert TokenNotAllowed(token);
        if (amount == 0) revert ZeroAmount();
        if (duration == 0 || duration <= FUNDING_WINDOW || duration > MAX_DURATION) revert InvalidDuration();

        escrowId = nextEscrowId++;
        escrows[escrowId] = EscrowData({
            seller: msg.sender,
            buyer: buyer,
            token: token,
            amount: amount,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + duration,
            state: EscrowState.CREATED,
            sellerConfirmation: Confirmation.NONE,
            buyerConfirmation: Confirmation.NONE,
            data: data
        });

        emit EscrowCreated(escrowId, msg.sender, buyer, token, amount, block.timestamp + duration, data);
    }

    /// @notice Cancel an unfunded escrow after the 24-hour funding window.
    /// @notice Anyone can cancel once the 24h funding window has expired.
    /// @param escrowId The escrow to cancel
    function cancelUnfunded(uint256 escrowId) external inState(escrowId, EscrowState.CREATED) {
        EscrowData storage escrow = escrows[escrowId];
        if (block.timestamp <= escrow.createdAt + FUNDING_WINDOW) revert FundingWindowNotExpired(escrowId);

        escrow.state = EscrowState.CANCELLED;
        emit EscrowCancelled(escrowId, msg.sender);
    }

    // ─────────────────────────────────────────────
    //  BUYER FUNCTIONS
    // ─────────────────────────────────────────────

    /// @notice Buyer funds the escrow — must be called within 24 hours of creation
    /// @param escrowId The escrow to fund
    function fundEscrow(uint256 escrowId) external onlyBuyer(escrowId) inState(escrowId, EscrowState.CREATED) {
        EscrowData storage escrow = escrows[escrowId];

        // Check 24-hour funding window
        if (block.timestamp > escrow.createdAt + FUNDING_WINDOW) revert FundingWindowExpired(escrowId);

        escrow.state = EscrowState.FUNDED;
        address token = escrow.token;
        // requires prior approval from buyer to transfer tokens
        IERC20(token).safeTransferFrom(msg.sender, address(this), escrow.amount);

        emit EscrowFunded(escrowId, msg.sender, escrow.amount, token);
    }

    // ─────────────────────────────────────────────
    //  CONFIRMATION FUNCTIONS
    // ─────────────────────────────────────────────

    /// @notice Seller or buyer confirms their preferred outcome
    /// @dev Reverts if confirming the same outcome again.
    ///      If both confirm the same outcome, it executes immediately.
    ///      Confirmations are locked after escrow expiry.
    /// @param escrowId The escrow to confirm
    /// @param confirmation RELEASE to release to seller, REFUND to return to buyer
    function confirm(uint256 escrowId, Confirmation confirmation) external inState(escrowId, EscrowState.FUNDED) {
        EscrowData storage escrow = escrows[escrowId];

        // Lock confirmations after expiry — owner mediates from here
        if (block.timestamp > escrow.expiresAt) revert EscrowExpired(escrowId);
        if (confirmation == Confirmation.NONE) revert InvalidConfirmation(confirmation);

        bool isSeller = msg.sender == escrow.seller;
        bool isBuyer = msg.sender == escrow.buyer;
        if (!isSeller && !isBuyer) revert NotParticipant();

        if (isSeller) {
            if (escrow.sellerConfirmation == confirmation) revert AlreadyConfirmed(confirmation);
            escrow.sellerConfirmation = confirmation;
        } else {
            if (escrow.buyerConfirmation == confirmation) revert AlreadyConfirmed(confirmation);
            escrow.buyerConfirmation = confirmation;
        }

        emit ConfirmationSubmitted(escrowId, msg.sender, confirmation);

        // Execute if both parties agree on the same outcome
        if (
            escrow.sellerConfirmation != Confirmation.NONE && escrow.buyerConfirmation != Confirmation.NONE
                && escrow.sellerConfirmation == escrow.buyerConfirmation
        ) {
            _finalize(escrowId, escrow, confirmation);
        }
    }

    // ─────────────────────────────────────────────
    //  INTERNAL FUNCTIONS
    // ─────────────────────────────────────────────

    /// @dev Finalize escrow based on agreed confirmation
    function _finalize(uint256 escrowId, EscrowData storage escrow, Confirmation confirmation) internal {
        uint256 grossAmount = escrow.amount;
        uint256 fee = (grossAmount * FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = grossAmount - fee;
        address token = escrow.token;
        if (confirmation == Confirmation.RELEASE) {
            // Transfer netAmount to seller, accumulate fee
            address seller = escrow.seller;
            escrow.state = EscrowState.RELEASED;
            accumulatedFees[token] += fee;
            IERC20(token).safeTransfer(seller, netAmount);
            emit EscrowReleased(escrowId, seller, netAmount, token);
        } else {
            // Transfer netAmount back to buyer, accumulate fee
            address buyer = escrow.buyer;
            escrow.state = EscrowState.REFUNDED;
            accumulatedFees[token] += fee;
            IERC20(token).safeTransfer(buyer, netAmount);
            emit EscrowRefunded(escrowId, buyer, netAmount, token);
        }
    }

    // ─────────────────────────────────────────────
    //  VIEW FUNCTIONS
    // ─────────────────────────────────────────────

    /// @notice Get full escrow details
    function getEscrow(uint256 escrowId) external view returns (EscrowData memory) {
        if (escrows[escrowId].seller == address(0)) revert EscrowNotFound(escrowId);
        return escrows[escrowId];
    }

    /// @notice Check if an escrow has expired
    function isExpired(uint256 escrowId) external view returns (bool) {
        return block.timestamp > escrows[escrowId].expiresAt;
    }
}
