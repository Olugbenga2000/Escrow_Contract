// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Escrow} from "../src/Escrow.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract DeployEscrow is Script {
    // 30 days max escrow duration
    uint256 public constant MAX_DURATION = 30 days;

    function run() external returns (Escrow, MockERC20) {
        // deploy mock USDC for testing
        MockERC20 usdc = deployMockToken("USDC", "USDC");
        // Add your whitelisted token addresses here
        address[] memory allowedTokens = new address[](1);
        allowedTokens[0] = address(usdc);

        Escrow escrowContract = deployEscrowWithTokens(MAX_DURATION, allowedTokens);

        console.log("Escrow deployed at:", address(escrowContract));
        console.log("Allowed token:", address(usdc));
        console.log("Max Duration:", escrowContract.MAX_DURATION());

        return (escrowContract, usdc);
    }

    function deployMockToken(string memory name, string memory symbol) public returns (MockERC20) {
        MockERC20 token = new MockERC20(name, symbol);
        console.log("Mock token deployed at:", address(token));
        return token;
    }

    function deployEscrowWithTokens(uint256 maxDuration, address[] memory tokens) public returns (Escrow) {
        vm.startBroadcast(address(this));
        Escrow escrowContract = new Escrow(maxDuration, tokens);
        vm.stopBroadcast();

        return escrowContract;
    }
}
