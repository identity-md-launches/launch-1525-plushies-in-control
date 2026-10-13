// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PICToken} from "src/PICToken.sol";
import {HolderClaim} from "src/HolderClaim.sol";
import {MockPFP} from "./mocks/MockPFP.sol";

/// @dev Metamorphic properties complement the existing example tests and schedule oracle.
/// forge-config: default.fuzz.runs = 1000
contract HolderClaimPropertiesTest is Test {
    uint256 private constant ALLOCATION = 800_000_000e18;
    uint256 private constant SHARE = ALLOCATION / 111;
    uint256 private constant DURATION = 20 days;
    PICToken private token;
    HolderClaim private distribution;
    MockPFP private pfp;
    address private alice;
    address private bob;

    function setUp() public {
        vm.warp(1_800_000_000);
        alice = makeAddr("properties alice");
        bob = makeAddr("properties bob");
        token = new PICToken();
        distribution = new HolderClaim(address(token));
        vm.etch(distribution.PFP(), address(new MockPFP()).code);
        pfp = MockPFP(distribution.PFP());
        pfp.initialize(alice);
        token.transfer(address(distribution), ALLOCATION);
    }

    function testFuzz_claimFrequencyDoesNotChangeEntitlement(uint32[12] memory gaps, uint32 rawEnd, uint8 rawId)
        public
    {
        uint256 id = bound(rawId, 1, 111);
        uint256 untouchedId = id % 111 + 1;
        uint256 end = bound(rawEnd, 1, DURATION);
        uint256 start = distribution.START();
        uint256 elapsed;
        uint256 frequentPaid;
        for (uint256 i; i < gaps.length; ++i) {
            elapsed += bound(gaps[i], 0, end - elapsed);
            vm.warp(start + elapsed);
            vm.prank(alice);
            frequentPaid += distribution.claim(_one(id));
        }
        vm.warp(start + end);
        vm.prank(alice);
        frequentPaid += distribution.claim(_one(id));
        vm.prank(alice);
        uint256 oncePaid = distribution.claim(_one(untouchedId));
        assertGt(oncePaid, 0);
        assertEq(frequentPaid, oncePaid, "claim frequency changed cumulative rounding");
        assertEq(token.balanceOf(alice), frequentPaid + oncePaid);

        vm.warp(start + DURATION);
        vm.prank(alice);
        frequentPaid += distribution.claim(_one(id));
        vm.prank(alice);
        oncePaid += distribution.claim(_one(untouchedId));
        assertEq(frequentPaid, SHARE);
        assertEq(oncePaid, SHARE);
    }

    function testFuzz_batchOrderAndChunkingPreservePayout(uint8[48] memory seeds, uint8 rawLength) public {
        // Cross word/byte boundaries and both ends of the valid ID range.
        uint256[9] memory candidates = [uint256(1), 2, 31, 32, 63, 64, 65, 110, 111];
        vm.warp(distribution.START() + 3 days);
        vm.prank(alice);
        distribution.claim(_one(1));
        vm.prank(alice);
        distribution.claim(_one(63));
        vm.prank(alice);
        distribution.claim(_one(111));
        vm.warp(distribution.START() + 7 days + 1);
        uint256 length = bound(rawLength, 1, seeds.length);
        uint256[] memory ids = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            ids[i] = candidates[uint256(seeds[i]) % candidates.length];
        }

        uint256 snapshot = vm.snapshotState();
        uint256 preview = distribution.claimableFor(alice, ids);
        vm.prank(alice);
        uint256 batched = distribution.claim(ids);
        uint256 batchBalance = token.balanceOf(alice);
        uint256[9] memory batchClaimed;
        for (uint256 i; i < candidates.length; ++i) {
            batchClaimed[i] = distribution.claimed(candidates[i]);
        }
        assertGt(batched, 0);
        assertEq(batched, preview);

        assertTrue(vm.revertToStateAndDelete(snapshot));
        uint256 split;
        // Reverse order, split into individual transactions, and keep all duplicates.
        for (uint256 i = ids.length; i > 0; --i) {
            vm.prank(alice);
            split += distribution.claim(_one(ids[i - 1]));
        }
        assertEq(split, batched, "permutation/chunking changed payout");
        assertEq(token.balanceOf(alice), batchBalance);
        assertEq(distribution.claimableFor(alice, ids), 0);
        for (uint256 i; i < candidates.length; ++i) {
            assertEq(distribution.claimed(candidates[i]), batchClaimed[i]);
            assertEq(pfp.ownerOf(candidates[i]), alice);
        }
    }

    function testFuzz_vestingSatisfiesFloorBoundsAndDoesNotDependOnOwnership(uint256 rawElapsed, uint8 rawId) public {
        uint256 elapsed = bound(rawElapsed, 0, type(uint256).max - distribution.START());
        uint256 id = bound(rawId, 1, 111);
        vm.warp(distribution.START() + elapsed);
        uint256 vested = distribution.vested(id);
        if (elapsed < DURATION) {
            // These inequalities uniquely define the integer floor without using the SUT's division.
            assertLe(vested * DURATION, SHARE * elapsed);
            assertGt((vested + 1) * DURATION, SHARE * elapsed);
        } else {
            assertEq(vested, SHARE);
        }
        vm.prank(alice);
        pfp.lock(id, type(uint32).max);
        assertEq(distribution.vested(id), vested);
        pfp.burn(id);
        assertEq(distribution.vested(id), vested);
        assertEq(distribution.claimable(id), vested);
        assertEq(distribution.claimableFor(alice, _one(id)), 0);
    }

    function test_underfundedByOneWeiRollsBackPriorAccountingThenExactFundingWorks() public {
        HolderClaim limited = new HolderClaim(address(token));
        uint256 start = limited.START();
        token.transfer(address(limited), SHARE);
        vm.warp(start + 5 days);
        vm.prank(alice);
        uint256 first = limited.claim(_one(1));
        vm.warp(start + DURATION);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 111;
        ids[2] = 1;
        uint256 owed = 2 * SHARE - first;
        token.transfer(address(limited), SHARE - 1);
        assertEq(token.balanceOf(address(limited)), owed - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(limited), owed - 1, owed)
        );
        vm.prank(alice);
        limited.claim(ids);
        assertEq(limited.claimed(1), first, "earlier claim was lost");
        assertEq(limited.claimed(111), 0, "failed batch consumed another ID");
        assertEq(token.balanceOf(alice), first);
        assertEq(token.balanceOf(address(limited)), owed - 1);

        token.transfer(address(limited), 1);
        vm.prank(alice);
        assertEq(limited.claim(ids), owed);
        assertEq(limited.claimed(1), SHARE);
        assertEq(limited.claimed(111), SHARE);
        assertEq(token.balanceOf(address(limited)), 0);
        assertEq(token.balanceOf(alice), 2 * SHARE);
    }

    function test_invalidBoundariesRejectEvenForZeroAccountAndZeroVesting() public {
        uint256[3] memory invalid = [uint256(0), 112, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            bytes memory reason = abi.encodeWithSelector(HolderClaim.InvalidId.selector, invalid[i]);
            vm.expectRevert(reason);
            distribution.claimableFor(address(0), _one(invalid[i]));
            uint256[] memory ids = new uint256[](2);
            ids[0] = 1;
            ids[1] = invalid[i];
            vm.expectRevert(reason);
            vm.prank(alice);
            distribution.claim(ids);
            assertEq(distribution.claimed(1), 0);
        }
        assertEq(token.balanceOf(address(distribution)), ALLOCATION);
    }

    function test_mixedHistoryEventsDescribeOnlyPaidIdsAndOneAggregateTransfer() public {
        vm.prank(alice);
        pfp.approve(bob, 111);
        vm.prank(alice);
        pfp.lock(2, type(uint32).max);
        vm.warp(distribution.START() + DURATION - 1);
        vm.prank(alice);
        uint256 priorPaid = distribution.claim(_one(2));
        vm.warp(distribution.START() + DURATION);
        vm.prank(alice);
        distribution.claim(_one(1));

        uint256[] memory ids = new uint256[](5);
        ids[0] = 1; // Fully paid: no Claimed event.
        ids[1] = 2; // Locked and one second short.
        ids[2] = 111; // Previously untouched.
        ids[3] = 2;
        ids[4] = 111;
        vm.recordLogs();
        vm.prank(alice);
        assertEq(distribution.claim(ids), 2 * SHARE - priorPaid);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        _assertClaimLog(logs[0], 2, SHARE - priorPaid);
        _assertClaimLog(logs[1], 111, SHARE);
        assertEq(logs[2].emitter, address(token));
        assertEq(logs[2].topics.length, 3);
        assertEq(logs[2].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[2].topics[1], bytes32(uint256(uint160(address(distribution)))));
        assertEq(logs[2].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[2].data, (uint256)), 2 * SHARE - priorPaid);
        assertEq(pfp.getApproved(111), bob, "claim changed NFT approval");
        assertEq(pfp.ownerOf(111), alice);
        assertEq(pfp.ownerOf(2), address(pfp));
        (address lockHolder, uint32 betaId) = pfp.tokenLocks(2);
        assertEq(lockHolder, alice);
        assertEq(betaId, type(uint32).max);
        assertEq(token.balanceOf(alice), 3 * SHARE);
    }

    function _assertClaimLog(Vm.Log memory entry, uint256 id, uint256 amount) private view {
        assertEq(entry.emitter, address(distribution));
        assertEq(entry.topics.length, 3);
        assertEq(entry.topics[0], keccak256("Claimed(address,uint256,uint256)"));
        assertEq(entry.topics[1], bytes32(uint256(uint160(alice))));
        assertEq(entry.topics[2], bytes32(id));
        assertEq(abi.decode(entry.data, (uint256)), amount);
    }

    function _one(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
