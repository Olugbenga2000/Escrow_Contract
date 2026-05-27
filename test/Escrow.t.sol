// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console, stdError} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {DeployEscrow} from "../script/DeployEscrow.s.sol";

contract EscrowTest is Test {
    Escrow public escrow;
    MockERC20 public mockToken;
    DeployEscrow public deployScript;

    address public owner;
    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    address public user = makeAddr("user");
    uint256 public MAX_DURATION;

    uint256 public constant ESCROW_AMOUNT = 1000e18;
    uint256 public constant ESCROW_DURATION = 7 days;
    uint256 public constant FEE = (ESCROW_AMOUNT * 100) / 10_000; // 1%
    uint256 public constant NET_AMOUNT = ESCROW_AMOUNT - FEE;

    // ─────────────────────────────────────────────
    //  SETUP
    // ─────────────────────────────────────────────

    function setUp() public {
        // Deploy Escrow contract using the deployment script
        deployScript = new DeployEscrow();
        owner = address(deployScript);
        (escrow, mockToken) = deployScript.run();
        MAX_DURATION = deployScript.MAX_DURATION();
        // Fund buyer
        mockToken.mint(buyer, ESCROW_AMOUNT * 10);
        vm.prank(buyer);
        mockToken.approve(address(escrow), type(uint256).max);
    }

    // ─────────────────────────────────────────────
    //  HELPERS
    // ─────────────────────────────────────────────

    function _createEscrow() internal returns (uint256 escrowId) {
        vm.prank(seller);
        escrowId = escrow.createEscrow(buyer, address(mockToken), ESCROW_AMOUNT, ESCROW_DURATION, "");
    }

    function _createAndFundEscrow() internal returns (uint256 escrowId) {
        escrowId = _createEscrow();
        vm.prank(buyer);
        escrow.fundEscrow(escrowId);
    }

    // ─────────────────────────────────────────────
    //  DEPLOYMENT TESTS
    // ─────────────────────────────────────────────

    function testDeploymentRevertsOnZeroDuration() public {
        address[] memory tokens = new address[](0);
        vm.expectRevert(Escrow.InvalidDuration.selector);
        deployScript.deployEscrowWithTokens(0, tokens);
    }

    function testDeploymentRevertsOnZeroAddressToken() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        deployScript.deployEscrowWithTokens(MAX_DURATION, tokens);
    }

    function testEscrowDeployment() public view {
        assertEq(escrow.OWNER(), owner);
        assertEq(escrow.MAX_DURATION(), MAX_DURATION);
        assertTrue(escrow.allowedTokens(address(mockToken)));
    }

    // ─────────────────────────────────────────────
    //  OWNER FUNCTION TESTS
    // ─────────────────────────────────────────────

    function testSetAllowedTokenRevertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(Escrow.NotOwner.selector);
        escrow.setAllowedToken(address(mockToken), false);
    }

    function testSetAllowedTokenRevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.setAllowedToken(address(0), true);
    }

    function testSetAllowedTokenRevertsWhenTokenAlreadySet() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Escrow.TokenAlreadySet.selector, address(mockToken), true));

        escrow.setAllowedToken(address(mockToken), true);
    }

    function testSetAllowedToken() public {
        MockERC20 mockWeth = deployScript.deployMockToken("WETH", "WETH");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(escrow));
        emit Escrow.TokenAllowed(address(mockWeth), true);
        escrow.setAllowedToken(address(mockWeth), true);
        assertTrue(escrow.allowedTokens(address(mockWeth)));
    }

    // ─────────────────────────────────────────────
    //  CREATE ESCROW TESTS
    // ─────────────────────────────────────────────
    function testCreateEscrowRevertsOnZeroBuyer() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.createEscrow(address(0), address(mockToken), ESCROW_AMOUNT, ESCROW_DURATION, "");
    }

    function testCreateEscrowRevertsIfBuyerIsSeller() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.BuyerCannotBeSeller.selector);
        escrow.createEscrow(seller, address(mockToken), ESCROW_AMOUNT, ESCROW_DURATION, "");
    }

    function testCreateEscrowRevertsOnDisallowedToken() public {
        MockERC20 mockToken2 = deployScript.deployMockToken("MockToken2", "MKT2");
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Escrow.TokenNotAllowed.selector, address(mockToken2)));
        escrow.createEscrow(buyer, address(mockToken2), ESCROW_AMOUNT, ESCROW_DURATION, "");
    }

    function testCreateEscrowRevertsOnZeroAmount() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.ZeroAmount.selector);
        escrow.createEscrow(buyer, address(mockToken), 0, ESCROW_DURATION, "");
    }

    function testCreateEscrowRevertsOnDurationExceedsMax() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.InvalidDuration.selector);
        escrow.createEscrow(buyer, address(mockToken), ESCROW_AMOUNT, MAX_DURATION + 1, "");
    }

    function testCreateEscrowRevertsOnZeroDuration() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.InvalidDuration.selector);
        escrow.createEscrow(buyer, address(mockToken), ESCROW_AMOUNT, 0, "");
    }

    function testCreateEscrowRevertsOnDurationTooShort() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.InvalidDuration.selector);
        escrow.createEscrow(buyer, address(mockToken), ESCROW_AMOUNT, 24 hours, "");
    }

    function testCreateEscrow() public {
        vm.prank(seller);
        bytes memory metadata = abi.encode("ipfs://QmXxx");
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.EscrowCreated(
            0, seller, buyer, address(mockToken), ESCROW_AMOUNT, block.timestamp + ESCROW_DURATION, metadata
        );
        uint256 escrowId = escrow.createEscrow(buyer, address(mockToken), ESCROW_AMOUNT, ESCROW_DURATION, metadata);
        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(escrowId, 0);
        assertEq(data.seller, seller);
        assertEq(data.buyer, buyer);
        assertEq(data.token, address(mockToken));
        assertEq(data.amount, ESCROW_AMOUNT);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.CREATED));
        assertEq(data.createdAt, block.timestamp);
        assertEq(data.expiresAt, block.timestamp + ESCROW_DURATION);
        assertEq(uint8(data.sellerConfirmation), uint8(Escrow.Confirmation.NONE));
        assertEq(uint8(data.buyerConfirmation), uint8(Escrow.Confirmation.NONE));
        assertEq(data.data, metadata);
    }

    function testCreateEscrowIncrementsId() public {
        uint256 id1 = _createEscrow();
        uint256 id2 = _createEscrow();
        assertEq(id1, 0);
        assertEq(id2, 1);
    }

    // ─────────────────────────────────────────────
    //  FUND ESCROW TESTS
    // ─────────────────────────────────────────────
    function testFundEscrowRevertsIfNotBuyer() public {
        uint256 escrowId = _createEscrow();
        vm.prank(user);
        vm.expectRevert(Escrow.NotBuyer.selector);
        escrow.fundEscrow(escrowId);
    }

    function testFundEscrowRevertsAfterFundingWindow() public {
        uint256 escrowId = _createEscrow();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.FundingWindowExpired.selector, escrowId));
        escrow.fundEscrow(escrowId);
    }

    function testFundEscrowRevertsIfAlreadyFunded() public {
        uint256 escrowId = _createAndFundEscrow();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.EscrowState.FUNDED, Escrow.EscrowState.CREATED)
        );
        escrow.fundEscrow(escrowId);
    }

    function testFundEscrowRevertsIfCancelled() public {
        uint256 escrowId = _createEscrow();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(user);
        escrow.cancelUnfunded(escrowId);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.InvalidState.selector, Escrow.EscrowState.CANCELLED, Escrow.EscrowState.CREATED
            )
        );
        escrow.fundEscrow(escrowId);
    }

    function testFundEscrow() public {
        uint256 escrowId = _createEscrow();
        uint256 buyerBalanceBefore = mockToken.balanceOf(buyer);
        uint256 contractBalanceBefore = mockToken.balanceOf(address(escrow));

        vm.prank(buyer);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.EscrowFunded(escrowId, buyer, ESCROW_AMOUNT, address(mockToken));
        escrow.fundEscrow(escrowId);

        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.FUNDED));
        assertEq(mockToken.balanceOf(buyer), buyerBalanceBefore - ESCROW_AMOUNT);
        assertEq(mockToken.balanceOf(address(escrow)), contractBalanceBefore + ESCROW_AMOUNT);
    }

    // ─────────────────────────────────────────────
    //  CANCEL UNFUNDED TESTS
    // ─────────────────────────────────────────────

    function testCancelEscrowRevertsIfFunded() public {
        uint256 escrowId = _createAndFundEscrow();
        vm.expectRevert(
            abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.EscrowState.FUNDED, Escrow.EscrowState.CREATED)
        );
        escrow.cancelUnfunded(escrowId);
    }

    function testCancelUnfundedEscrowRevertsIfWindowNotExpired() public {
        uint256 escrowId = _createEscrow();
        vm.expectRevert(abi.encodeWithSelector(Escrow.FundingWindowNotExpired.selector, escrowId));
        escrow.cancelUnfunded(escrowId);
    }

    function testCancelUnfunded() public {
        uint256 escrowId = _createEscrow();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(user); // anyone can cancel if unfunded and expired
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.EscrowCancelled(escrowId, user);
        escrow.cancelUnfunded(escrowId);

        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.CANCELLED));
    }

    // ─────────────────────────────────────────────
    //  CONFIRM
    // ─────────────────────────────────────────────
    function testConfirmRevertsIfCreatedOrCancelled() public {
        uint256 escrowId = _createEscrow();
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.EscrowState.CREATED, Escrow.EscrowState.FUNDED)
        );
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);

        vm.warp(block.timestamp + 24 hours + 1);
        escrow.cancelUnfunded(escrowId);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.InvalidState.selector, Escrow.EscrowState.CANCELLED, Escrow.EscrowState.FUNDED
            )
        );
        escrow.confirm(escrowId, Escrow.Confirmation.REFUND);
    }

    function testConfirmRevertsAfterExpiry() public {
        uint256 escrowId = _createAndFundEscrow();
        vm.warp(block.timestamp + ESCROW_DURATION + 1);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Escrow.EscrowExpired.selector, escrowId));
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);
    }

    function testConfirmRevertsIfNone() public {
        uint256 escrowId = _createAndFundEscrow();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidConfirmation.selector, Escrow.Confirmation.NONE));
        escrow.confirm(escrowId, Escrow.Confirmation.NONE);
    }

    function testConfirmRevertsIfNotParticipant() public {
        uint256 escrowId = _createAndFundEscrow();
        vm.prank(user);
        vm.expectRevert(Escrow.NotParticipant.selector);
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);
    }

    function testConfirmRevertsOnDuplicateConfirmation() public {
        uint256 escrowId = _createAndFundEscrow();

        vm.prank(buyer);
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.AlreadyConfirmed.selector, Escrow.Confirmation.RELEASE));
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);
    }

    function testConfirmBothConfirmRelease() public {
        uint256 escrowId = _createAndFundEscrow();
        uint256 sellerBalanceBefore = mockToken.balanceOf(seller);
        uint256 contractBalanceBefore = mockToken.balanceOf(address(escrow));

        vm.prank(seller);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.ConfirmationSubmitted(escrowId, seller, Escrow.Confirmation.RELEASE);
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);
        assertEq(uint8(escrow.getEscrow(escrowId).sellerConfirmation), uint8(Escrow.Confirmation.RELEASE));

        vm.prank(buyer);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.EscrowReleased(escrowId, seller, NET_AMOUNT, address(mockToken));
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);

        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.RELEASED));
        assertEq(uint8(data.buyerConfirmation), uint8(Escrow.Confirmation.RELEASE));
        assertEq(mockToken.balanceOf(seller), sellerBalanceBefore + NET_AMOUNT);
        assertEq(mockToken.balanceOf(address(escrow)), contractBalanceBefore - NET_AMOUNT);
        assertEq(escrow.accumulatedFees(address(mockToken)), FEE);
    }

    function testConfirmBothConfirmRefund() public {
        uint256 escrowId = _createAndFundEscrow();
        uint256 buyerBalanceBefore = mockToken.balanceOf(buyer);
        uint256 contractBalanceBefore = mockToken.balanceOf(address(escrow));

        vm.prank(buyer);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.ConfirmationSubmitted(escrowId, buyer, Escrow.Confirmation.REFUND);
        escrow.confirm(escrowId, Escrow.Confirmation.REFUND);
        assertEq(uint8(escrow.getEscrow(escrowId).buyerConfirmation), uint8(Escrow.Confirmation.REFUND));

        vm.prank(seller);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.EscrowRefunded(escrowId, buyer, NET_AMOUNT, address(mockToken));
        escrow.confirm(escrowId, Escrow.Confirmation.REFUND);

        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.REFUNDED));
        assertEq(mockToken.balanceOf(buyer), buyerBalanceBefore + NET_AMOUNT);
        assertEq(mockToken.balanceOf(address(escrow)), contractBalanceBefore - NET_AMOUNT);
        assertEq(escrow.accumulatedFees(address(mockToken)), FEE);
    }

    function testConfirmDisagreementDoesNotExecute() public {
        uint256 escrowId = _createAndFundEscrow();

        vm.prank(seller);
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);

        vm.prank(buyer);
        escrow.confirm(escrowId, Escrow.Confirmation.REFUND);

        // State should still be FUNDED — no auto-execution on disagreement
        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.FUNDED));
        assertEq(uint8(data.sellerConfirmation), uint8(Escrow.Confirmation.RELEASE));
        assertEq(uint8(data.buyerConfirmation), uint8(Escrow.Confirmation.REFUND));
        assertEq(mockToken.balanceOf(address(escrow)), ESCROW_AMOUNT); // Funds still in contract
    }

    function testConfirmPartyCanChangeConfirmation() public {
        uint256 escrowId = _createAndFundEscrow();

        // Seller initially confirms refund
        vm.prank(seller);
        escrow.confirm(escrowId, Escrow.Confirmation.REFUND);
        assertEq(uint8(escrow.getEscrow(escrowId).sellerConfirmation), uint8(Escrow.Confirmation.REFUND));
        assertEq(uint8(escrow.getEscrow(escrowId).buyerConfirmation), uint8(Escrow.Confirmation.NONE));
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(Escrow.EscrowState.FUNDED));

        // Seller changes to release
        vm.prank(seller);
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);
        assertEq(uint8(escrow.getEscrow(escrowId).sellerConfirmation), uint8(Escrow.Confirmation.RELEASE));
        assertEq(uint8(escrow.getEscrow(escrowId).buyerConfirmation), uint8(Escrow.Confirmation.NONE));
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(Escrow.EscrowState.FUNDED));

        // Buyer also confirms release — should execute
        vm.prank(buyer);
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);

        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.RELEASED));
        assertEq(uint8(data.sellerConfirmation), uint8(Escrow.Confirmation.RELEASE));
        assertEq(uint8(data.buyerConfirmation), uint8(Escrow.Confirmation.RELEASE));
    }

    // ─────────────────────────────────────────────
    //  MEDIATION TESTS
    // ─────────────────────────────────────────────
    function testMediateRevertsIfNotOwner() public {
        uint256 escrowId = _createAndFundEscrow();
        vm.prank(user);
        vm.expectRevert(Escrow.NotOwner.selector);
        escrow.mediate(escrowId, Escrow.Confirmation.RELEASE);
    }

    function testMediateRevertsIfEscrowCancelledOrNotFunded() public {
        uint256 escrowId = _createEscrow();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.EscrowState.CREATED, Escrow.EscrowState.FUNDED)
        );
        escrow.mediate(escrowId, Escrow.Confirmation.RELEASE);

        vm.warp(block.timestamp + 24 hours + 1);
        escrow.cancelUnfunded(escrowId);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.InvalidState.selector, Escrow.EscrowState.CANCELLED, Escrow.EscrowState.FUNDED
            )
        );
        escrow.mediate(escrowId, Escrow.Confirmation.RELEASE);
    }

    function testMediateRevertsIfNotExpired() public {
        uint256 escrowId = _createAndFundEscrow();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Escrow.EscrowNotExpired.selector, escrowId));
        escrow.mediate(escrowId, Escrow.Confirmation.RELEASE);
    }

    function testMediateRevertsIfNone() public {
        uint256 escrowId = _createAndFundEscrow();
        vm.warp(block.timestamp + ESCROW_DURATION + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidConfirmation.selector, Escrow.Confirmation.NONE));
        escrow.mediate(escrowId, Escrow.Confirmation.NONE);
    }

    function testMediateRelease() public {
        uint256 escrowId = _createAndFundEscrow();
        uint256 sellerBalanceBefore = mockToken.balanceOf(seller);

        vm.warp(block.timestamp + ESCROW_DURATION + 1);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.MediatorResolved(escrowId, Escrow.Confirmation.RELEASE);
        escrow.mediate(escrowId, Escrow.Confirmation.RELEASE);

        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.RELEASED));
        assertEq(mockToken.balanceOf(seller), sellerBalanceBefore + NET_AMOUNT);
        assertEq(escrow.accumulatedFees(address(mockToken)), FEE);
    }

    function testMediateRefund() public {
        uint256 escrowId = _createAndFundEscrow();
        uint256 buyerBalanceBefore = mockToken.balanceOf(buyer);

        vm.warp(block.timestamp + ESCROW_DURATION + 1);

        vm.prank(owner);
        escrow.mediate(escrowId, Escrow.Confirmation.REFUND);

        Escrow.EscrowData memory data = escrow.getEscrow(escrowId);
        assertEq(uint8(data.state), uint8(Escrow.EscrowState.REFUNDED));
        assertEq(mockToken.balanceOf(buyer), buyerBalanceBefore + NET_AMOUNT);
    }

    // ─────────────────────────────────────────────
    //  FEE WITHDRAWAL TESTS
    // ─────────────────────────────────────────────
    function testWithdrawFeesRevertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(Escrow.NotOwner.selector);
        escrow.withdrawFees(address(mockToken), FEE);
    }

    function testWithdrawFeesRevertsIfZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Escrow.NoFeesToWithdraw.selector, 0));
        escrow.withdrawFees(address(mockToken), 0);
    }

    function testWithdrawFees() public {
        uint256 escrowId = _createAndFundEscrow();
        vm.prank(seller);
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);
        vm.prank(buyer);
        escrow.confirm(escrowId, Escrow.Confirmation.RELEASE);

        uint256 ownerBalanceBefore = mockToken.balanceOf(owner);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Escrow.FeesWithdrawn(address(mockToken), FEE);
        escrow.withdrawFees(address(mockToken), FEE);

        assertEq(mockToken.balanceOf(owner), ownerBalanceBefore + FEE);
        assertEq(escrow.accumulatedFees(address(mockToken)), 0);
    }

    function testWithdrawFeesRevertsIfAmountExceedsAccumulatedFees() public {
        uint256 escrowId = _createAndFundEscrow();
        vm.prank(seller);
        escrow.confirm(escrowId, Escrow.Confirmation.REFUND);
        vm.prank(buyer);
        escrow.confirm(escrowId, Escrow.Confirmation.REFUND);

        vm.prank(owner);
        vm.expectRevert(stdError.arithmeticError);
        escrow.withdrawFees(address(mockToken), FEE + 1);
    }

    // ─────────────────────────────────────────────
    //  FEE ACCOUNTING ACROSS MULTIPLE ESCROWS
    // ─────────────────────────────────────────────

    function testFeesAccumulateAcrossMultipleEscrows() public {
        // Escrow 1 — released
        uint256 escrowId1 = _createAndFundEscrow();
        vm.prank(seller);
        escrow.confirm(escrowId1, Escrow.Confirmation.RELEASE);
        vm.prank(buyer);
        escrow.confirm(escrowId1, Escrow.Confirmation.RELEASE);

        // Escrow 2 — refunded
        uint256 escrowId2 = _createAndFundEscrow();
        vm.prank(buyer);
        escrow.confirm(escrowId2, Escrow.Confirmation.REFUND);
        vm.prank(seller);
        escrow.confirm(escrowId2, Escrow.Confirmation.REFUND);

        // Both escrows should contribute fees
        assertEq(escrow.accumulatedFees(address(mockToken)), FEE * 2);

        //Escrow 3 — adds another token
        MockERC20 mockToken2 = deployScript.deployMockToken("MockToken2", "MKT2");
        vm.prank(owner);
        escrow.setAllowedToken(address(mockToken2), true);
        vm.prank(seller);
        uint256 escrowId3 = escrow.createEscrow(buyer, address(mockToken2), ESCROW_AMOUNT, ESCROW_DURATION, "");
        mockToken2.mint(buyer, ESCROW_AMOUNT * 10);
        vm.startPrank(buyer);
        mockToken2.approve(address(escrow), type(uint256).max);
        escrow.fundEscrow(escrowId3);
        vm.stopPrank();
        vm.prank(seller);
        escrow.confirm(escrowId3, Escrow.Confirmation.RELEASE);
        vm.prank(buyer);
        escrow.confirm(escrowId3, Escrow.Confirmation.RELEASE);
        assertEq(escrow.accumulatedFees(address(mockToken2)), FEE);
    }

    // ─────────────────────────────────────────────
    //  VIEW FUNCTION TESTS
    // ─────────────────────────────────────────────

    function testGetEscrowRevertsOnNonExistent() public {
        vm.expectRevert(abi.encodeWithSelector(Escrow.EscrowNotFound.selector, 999));
        escrow.getEscrow(999);
    }

    function test_isExpired() public {
        uint256 escrowId = _createAndFundEscrow();
        assertFalse(escrow.isExpired(escrowId));
        vm.warp(block.timestamp + ESCROW_DURATION + 1);
        assertTrue(escrow.isExpired(escrowId));
    }
}
