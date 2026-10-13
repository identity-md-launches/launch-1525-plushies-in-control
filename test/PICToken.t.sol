// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PICToken} from "../src/PICToken.sol";
import {HolderClaim} from "../src/HolderClaim.sol";

/// @dev Offline allocation simulation only; the production launch factory is supplied by IMD.
contract LaunchAllocationHarness {
    uint256 public balanceAfterApplicationDeployment;

    function launch(address pool, address swarm) external returns (PICToken token, HolderClaim distribution) {
        token = new PICToken();
        distribution = new HolderClaim(address(token));
        balanceAfterApplicationDeployment = token.balanceOf(address(this));
        token.transfer(swarm, 100_000_000e18);
        token.transfer(pool, 100_000_000e18);
        token.transfer(address(distribution), 800_000_000e18);
    }
}

contract PICTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    PICToken internal token;
    address internal alice;
    address internal bob;

    function setUp() public {
        token = new PICToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_metadataAndWholeSupplyMintedToDeployer() public view {
        assertEq(token.name(), "Plushies In Control");
        assertEq(token.symbol(), "PIC");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_launchAllocationAndAllTransferFlowsArriveWhole() public {
        address pool = makeAddr("simulated pool manager");
        address swarm = makeAddr("simulated swarm distributor");
        LaunchAllocationHarness factory = new LaunchAllocationHarness();
        (PICToken launched, HolderClaim distribution) = factory.launch(pool, swarm);
        assertEq(factory.balanceAfterApplicationDeployment(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(address(distribution)), 800_000_000e18);
        assertEq(launched.balanceOf(swarm), 100_000_000e18);
        assertEq(launched.balanceOf(pool), 100_000_000e18);
        assertEq(address(distribution.token()), address(launched));
        assertEq(distribution.START(), block.timestamp);

        vm.prank(swarm);
        assertTrue(launched.transfer(alice, 100_000_000e18));
        assertEq(launched.balanceOf(alice), 100_000_000e18);
        // PIC side of buy, sell, and ordinary wallet transfer; actual pool swaps belong to the launch verifier.
        vm.prank(pool);
        assertTrue(launched.transfer(bob, 1e18));
        vm.prank(bob);
        assertTrue(launched.transfer(pool, 1e18));
        vm.prank(alice);
        assertTrue(launched.transfer(bob, 3e18));
        assertEq(launched.balanceOf(bob), 3e18);
        assertEq(launched.balanceOf(pool), 100_000_000e18);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_approvalsTransferFromAndRevocation() public {
        token.transfer(alice, 100e18);
        vm.prank(alice);
        assertTrue(token.approve(bob, 40e18));
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 25e18));
        assertEq(token.allowance(alice, bob), 15e18);
        assertEq(token.balanceOf(alice), 75e18);
        assertEq(token.balanceOf(bob), 25e18);
        vm.prank(alice);
        token.approve(bob, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
    }

    function test_deployerCannotSpendUnapprovedHolderTokens() public {
        token.transfer(alice, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1e18)
        );
        token.transferFrom(alice, address(this), 1e18);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_insufficientBalanceAndInvalidReceiverRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_zeroAndSelfTransfersPreserveSupply() public {
        assertTrue(token.transfer(alice, 0));
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noMintBurnPauseSeizureOrUpgradeEntryPoints() public {
        token.transfer(alice, 100e18);
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, SUPPLY);
            (bool deployerSuccess,) = address(token).call(data);
            assertFalse(deployerSuccess);
            vm.prank(bob);
            (bool outsiderSuccess,) = address(token).call(data);
            assertFalse(outsiderSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 100e18);
        vm.prank(alice);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(bob), 100e18);
    }

    function testFuzz_transfersConserveFixedSupply(uint256 amount, uint256 onward) public {
        amount = bound(amount, 0, SUPPLY);
        onward = bound(onward, 0, amount);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(bob, onward);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount - onward);
        assertEq(token.balanceOf(bob), onward);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
