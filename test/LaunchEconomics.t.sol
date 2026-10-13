// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PICToken} from "../src/PICToken.sol";
import {HolderClaim} from "../src/HolderClaim.sol";
import {LaunchEconomics} from "../src/LaunchEconomics.sol";
import {MockPFP} from "./mocks/MockPFP.sol";

/// @dev External wrappers so the tests can expect reverts from the inlined library functions.
contract LaunchEconomicsExposer {
    function split(uint256 supply, uint256 poolBps, uint256 swarmBps)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return LaunchEconomics.split(supply, poolBps, swarmBps);
    }

    function launchSplit() external pure returns (uint256, uint256, uint256) {
        return LaunchEconomics.launchSplit();
    }
}

/// @dev Offline stand-in for the launch factory: deploys both artifacts and distributes the supply in one
/// transaction under the manifest economics it is given. The real factory and pool are supplied by IMD.
contract SimulatedLaunch {
    struct Economics {
        uint256 poolBps;
        uint256 swarmBps;
        address pool;
        address swarm;
        /// @dev Zero means "resolve to the deployed HolderClaim by name", as the manifest step does.
        address remainderTo;
    }

    uint256 public supplyHeldAfterDeployment;

    function launch(Economics memory economics) external returns (PICToken token, HolderClaim claim) {
        token = new PICToken();
        claim = new HolderClaim(address(token));
        supplyHeldAfterDeployment = token.balanceOf(address(this));
        (uint256 pool, uint256 swarm, uint256 remainder) =
            LaunchEconomics.split(supplyHeldAfterDeployment, economics.poolBps, economics.swarmBps);
        address remainderTo = economics.remainderTo == address(0) ? address(claim) : economics.remainderTo;
        token.transfer(economics.pool, pool);
        token.transfer(economics.swarm, swarm);
        token.transfer(remainderTo, remainder);
    }
}

contract LaunchEconomicsTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant ALLOCATION = 800_000_000e18;
    uint256 internal constant SHARE = ALLOCATION / 111;
    /// @dev What HolderClaim can ever pay out: the allocation minus the 23 base units of division dust.
    uint256 internal constant OWED = SHARE * 111;
    uint256 internal constant VESTING = 20 days;

    LaunchEconomicsExposer internal economics;
    SimulatedLaunch internal factory;
    address internal pool;
    address internal swarm;
    address internal formerRemainderWallet;
    address internal alice;

    function setUp() public {
        vm.warp(1_800_000_000);
        economics = new LaunchEconomicsExposer();
        factory = new SimulatedLaunch();
        pool = makeAddr("simulated PIC/FWA pool");
        swarm = makeAddr("simulated swarm distributor");
        formerRemainderWallet = makeAddr("wallet the earlier economics named as remainderTo");
        alice = makeAddr("alice");
    }

    // ---------------------------------------------------------------- constants

    function test_launchSplitIsTenTenEightyAndMatchesContractConstants() public view {
        (uint256 poolShare, uint256 swarmShare, uint256 remainder) = economics.launchSplit();
        assertEq(LaunchEconomics.POOL_BPS, 1000);
        assertEq(LaunchEconomics.SWARM_BPS, 1000);
        assertEq(LaunchEconomics.HOLDER_CLAIM_BPS, 8000);
        assertEq(LaunchEconomics.TOTAL_SUPPLY, SUPPLY);
        assertEq(poolShare, 100_000_000e18);
        assertEq(swarmShare, 100_000_000e18);
        assertEq(remainder, ALLOCATION);
        assertEq(poolShare + swarmShare + remainder, SUPPLY);
        assertEq(LaunchEconomics.POOL_ALLOCATION, poolShare);
        assertEq(LaunchEconomics.SWARM_ALLOCATION, swarmShare);
        assertEq(LaunchEconomics.HOLDER_CLAIM_ALLOCATION, remainder);
    }

    function test_tokenSupplyAndHolderClaimAllocationAreTiedToTheEconomics() public {
        PICToken token = new PICToken();
        HolderClaim claim = new HolderClaim(address(token));
        assertEq(token.INITIAL_SUPPLY(), LaunchEconomics.TOTAL_SUPPLY);
        assertEq(claim.ALLOCATION(), LaunchEconomics.HOLDER_CLAIM_ALLOCATION);
        assertEq(claim.ALLOCATION(), ALLOCATION);
        assertEq(claim.SHARE(), SHARE);
        assertEq(claim.SHARE() * claim.MAX_ID() + 23, claim.ALLOCATION());
    }

    function test_splitRejectsSharesAboveTheWholeSupply() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchEconomics.SharesExceedSupply.selector, 9500, 1000));
        economics.split(SUPPLY, 9500, 1000);
        vm.expectRevert(abi.encodeWithSelector(LaunchEconomics.SharesExceedSupply.selector, 10_000, 1));
        economics.split(SUPPLY, 10_000, 1);
        (uint256 poolShare, uint256 swarmShare, uint256 remainder) = economics.split(SUPPLY, 9000, 1000);
        assertEq(remainder, 0);
        assertEq(poolShare + swarmShare, SUPPLY);
    }

    function testFuzz_splitConservesSupplyAndGivesRoundingToRemainder(uint256 supply, uint16 poolBps, uint16 swarmBps)
        public
        view
    {
        supply = bound(supply, 0, type(uint256).max / 10_000);
        poolBps = uint16(bound(poolBps, 0, 10_000));
        swarmBps = uint16(bound(swarmBps, 0, 10_000 - poolBps));
        (uint256 poolShare, uint256 swarmShare, uint256 remainder) = economics.split(supply, poolBps, swarmBps);
        assertEq(poolShare + swarmShare + remainder, supply);
        assertLe(poolShare, supply * poolBps / 10_000);
        assertLe(swarmShare, supply * swarmBps / 10_000);
        assertGe(remainder, supply * (10_000 - poolBps - swarmBps) / 10_000);
    }

    // ------------------------------------------------------------------ success

    function test_launchTransactionFundsHolderClaimWithTheWholeRemainder() public {
        (PICToken token, HolderClaim claim) = factory.launch(_optionOne());
        assertEq(factory.supplyHeldAfterDeployment(), SUPPLY, "factory did not hold the supply first");
        assertEq(token.balanceOf(pool), 100_000_000e18, "pool share");
        assertEq(token.balanceOf(swarm), 100_000_000e18, "swarm share");
        assertEq(token.balanceOf(address(claim)), ALLOCATION, "HolderClaim funding");
        assertEq(token.balanceOf(address(factory)), 0, "factory kept PIC");
        assertEq(token.balanceOf(formerRemainderWallet), 0, "earlier remainder wallet must receive nothing");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(address(claim.token()), address(token));
        assertEq(claim.START(), block.timestamp, "vesting starts in the launch transaction");
        assertEq(claim.fundingShortfall(), 0);
        assertTrue(claim.isFunded());
    }

    function test_fundedLaunchPaysEveryShareAndStaysFundedThroughout() public {
        (PICToken token, HolderClaim claim) = factory.launch(_optionOne());
        MockPFP pfp = _installPfp(claim);

        vm.warp(claim.START() + 7 days);
        vm.prank(alice);
        claim.claim(_range(1, 40));
        assertEq(claim.fundingShortfall(), 0, "claims never create a shortfall");
        assertTrue(claim.isFunded());

        vm.warp(claim.START() + VESTING);
        vm.prank(alice);
        claim.claim(_range(1, 111));
        assertEq(token.balanceOf(alice), SHARE * 111);
        assertEq(token.balanceOf(address(claim)), ALLOCATION % 111);
        assertEq(claim.fundingShortfall(), 0);
        assertTrue(claim.isFunded());
        assertEq(pfp.ownerOf(1), alice);
    }

    // ------------------------------------------------------------------ failure

    function test_formerEconomicsWithPoolBps8800CannotFundHolderClaim() public {
        SimulatedLaunch.Economics memory former = _optionOne();
        former.poolBps = 8800;
        (PICToken token, HolderClaim claim) = factory.launch(former);
        assertEq(token.balanceOf(pool), 880_000_000e18);
        assertEq(token.balanceOf(swarm), 100_000_000e18);
        assertEq(token.balanceOf(address(claim)), 20_000_000e18, "only 2% is left for HolderClaim");
        assertEq(claim.fundingShortfall(), OWED - 20_000_000e18);
        assertFalse(claim.isFunded());

        _installPfp(claim);
        vm.warp(claim.START() + VESTING);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(claim), 20_000_000e18, SHARE * 111
            )
        );
        vm.prank(alice);
        claim.claim(_range(1, 111));
        assertEq(claim.claimed(1), 0, "failed batch left accounting behind");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_remainderRoutedToAWalletLeavesHolderClaimEmptyUntilTheWalletForwardsIt() public {
        SimulatedLaunch.Economics memory misrouted = _optionOne();
        misrouted.remainderTo = formerRemainderWallet;
        (PICToken token, HolderClaim claim) = factory.launch(misrouted);
        assertEq(token.balanceOf(formerRemainderWallet), ALLOCATION);
        assertEq(token.balanceOf(address(claim)), 0);
        assertEq(claim.fundingShortfall(), OWED);
        assertFalse(claim.isFunded());

        _installPfp(claim);
        vm.warp(claim.START() + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(claim), 0, SHARE / 20)
        );
        vm.prank(alice);
        claim.claim(_range(1, 1));

        // Vesting kept running while unfunded; a later deposit of the full remainder repairs the launch.
        vm.prank(formerRemainderWallet);
        token.transfer(address(claim), ALLOCATION);
        assertEq(claim.fundingShortfall(), 0);
        assertTrue(claim.isFunded());
        vm.prank(alice);
        assertEq(claim.claim(_range(1, 1)), SHARE / 20);
    }

    function test_shortfallMovesOnlyWithDepositsNotWithClaims() public {
        PICToken token = new PICToken();
        HolderClaim claim = new HolderClaim(address(token));
        _installPfp(claim);
        token.transfer(address(claim), ALLOCATION / 2);
        assertEq(claim.fundingShortfall(), OWED - ALLOCATION / 2);

        vm.warp(claim.START() + 10 days);
        vm.prank(alice);
        claim.claim(_range(1, 111));
        assertEq(claim.fundingShortfall(), OWED - ALLOCATION / 2, "paying vested shares did not change it");
        assertFalse(claim.isFunded());

        token.transfer(address(claim), OWED - ALLOCATION / 2 - 1);
        assertEq(claim.fundingShortfall(), 1);
        token.transfer(address(claim), 1);
        assertEq(claim.fundingShortfall(), 0);
        assertTrue(claim.isFunded());

        // The 23 base units of dust and any later deposit are surplus, never a negative shortfall.
        token.transfer(address(claim), 23 + 5e18);
        assertEq(claim.fundingShortfall(), 0);
    }

    function test_fundingViewsHaveNoSideEffectsAndNoAdminPath() public {
        (PICToken token, HolderClaim claim) = factory.launch(_optionOne());
        uint256 before = token.balanceOf(address(claim));
        vm.prank(alice);
        assertTrue(claim.isFunded());
        assertEq(token.balanceOf(address(claim)), before);
        (bool ok,) = address(claim).call(abi.encodeWithSignature("fund(uint256)", 1));
        assertFalse(ok);
        (ok,) = address(claim).call(abi.encodeWithSignature("setAllocation(uint256)", 1));
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ helpers

    function _optionOne() internal view returns (SimulatedLaunch.Economics memory) {
        return SimulatedLaunch.Economics({
            poolBps: LaunchEconomics.POOL_BPS,
            swarmBps: LaunchEconomics.SWARM_BPS,
            pool: pool,
            swarm: swarm,
            remainderTo: address(0)
        });
    }

    function _installPfp(HolderClaim claim) internal returns (MockPFP pfp) {
        vm.etch(claim.PFP(), address(new MockPFP()).code);
        pfp = MockPFP(claim.PFP());
        pfp.initialize(alice);
    }

    function _range(uint256 from, uint256 to) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](to - from + 1);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = from + i;
        }
    }
}
