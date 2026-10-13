// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PICToken} from "../src/PICToken.sol";
import {HolderClaim} from "../src/HolderClaim.sol";
import {MockPFP} from "./mocks/MockPFP.sol";

contract HolderClaimTest is Test {
    uint256 internal constant ALLOCATION = 800_000_000e18;
    uint256 internal constant SHARE = ALLOCATION / 111;
    uint256 internal constant VESTING = 20 days;

    PICToken internal token;
    HolderClaim internal distribution;
    MockPFP internal pfp;
    address internal alice;
    address internal bob;

    function setUp() public {
        vm.warp(1_800_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        token = new PICToken();
        distribution = new HolderClaim(address(token));
        MockPFP implementation = new MockPFP();
        vm.etch(distribution.PFP(), address(implementation).code);
        pfp = MockPFP(distribution.PFP());
        pfp.initialize(alice);
        token.transfer(address(distribution), ALLOCATION);
    }

    function test_constantsAndConstructor() public view {
        assertEq(address(distribution.token()), address(token));
        assertEq(distribution.START(), 1_800_000_000);
        assertEq(distribution.PFP(), 0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620);
        assertEq(distribution.MIN_ID(), 1);
        assertEq(distribution.MAX_ID(), 111);
        assertEq(distribution.SHARE(), SHARE);
        assertEq(distribution.VESTING(), VESTING);
        assertEq(distribution.claimed(1), 0);
        assertEq(distribution.vested(1), 0);
        assertEq(distribution.claimable(111), 0);
    }

    function test_constructorDoesNotCallExternalContractsOrMoveSupply() public {
        vm.etch(distribution.PFP(), "");
        address futureToken = makeAddr("future token without code");
        HolderClaim emptyChainClaim = new HolderClaim(futureToken);
        assertEq(address(emptyChainClaim.token()), futureToken);
        assertEq(emptyChainClaim.START(), block.timestamp);

        uint256 before = token.balanceOf(address(this));
        HolderClaim another = new HolderClaim(address(token));
        assertEq(token.balanceOf(address(this)), before);
        assertEq(token.balanceOf(address(another)), 0);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(HolderClaim.InvalidToken.selector);
        new HolderClaim(address(0));
    }

    function test_vestsPerSecondAndCapsAtTwentyDays() public {
        uint256 start = distribution.START();
        uint256[8] memory elapsed = [uint256(0), 1, 12 hours, 1 days, 19 days, VESTING - 1, VESTING, 365 days];
        for (uint256 i; i < elapsed.length; ++i) {
            vm.warp(start + elapsed[i]);
            uint256 expected = SHARE * (elapsed[i] > VESTING ? VESTING : elapsed[i]) / VESTING;
            assertEq(distribution.vested(1), expected);
            assertEq(distribution.vested(111), expected);
        }
        vm.warp(type(uint256).max);
        assertEq(distribution.vested(1), SHARE);
    }

    function test_claimAtStartIsNoop() public {
        vm.recordLogs();
        vm.prank(alice);
        assertEq(distribution.claim(_ids(1)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(distribution.claimed(1), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_dailyClaimsPayCumulativeDifferenceWithoutLosingRounding() public {
        uint256 start = distribution.START();
        uint256 paid;
        for (uint256 day = 1; day <= 20; ++day) {
            vm.warp(start + day * 1 days);
            uint256 expected = SHARE * day / 20;
            vm.prank(alice);
            assertEq(distribution.claim(_ids(1)), expected - paid);
            paid = expected;
            assertEq(distribution.claimed(1), expected);
            assertEq(token.balanceOf(alice), expected);
            assertEq(distribution.claimable(1), 0);
        }
        assertEq(paid, SHARE);
    }

    function test_batchPaysOnceAndDuplicatesDoNotDoubleCount() public {
        vm.warp(distribution.START() + 1 days);
        uint256[] memory ids = new uint256[](5);
        ids[0] = 111;
        ids[1] = 1;
        ids[2] = 111;
        ids[3] = 2;
        ids[4] = 1;
        uint256 perId = SHARE / 20;
        assertEq(distribution.claimableFor(alice, ids), perId * 3);

        vm.recordLogs();
        vm.prank(alice);
        assertEq(distribution.claim(ids), perId * 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4);
        for (uint256 i; i < 3; ++i) {
            assertEq(logs[i].emitter, address(distribution));
            assertEq(logs[i].topics[0], keccak256("Claimed(address,uint256,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(alice))));
            assertEq(abi.decode(logs[i].data, (uint256)), perId);
        }
        assertEq(logs[3].emitter, address(token));
        assertEq(logs[3].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(abi.decode(logs[3].data, (uint256)), perId * 3);
        assertEq(token.balanceOf(alice), perId * 3);
        assertEq(distribution.claimed(111), perId);
        assertEq(distribution.claimed(1), perId);
        assertEq(distribution.claimed(2), perId);
        assertEq(distribution.claimed(3), 0);
        assertEq(pfp.ownerOf(1), alice);

        vm.recordLogs();
        vm.prank(alice);
        assertEq(distribution.claim(ids), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_emptyBatchIsNoop() public {
        vm.warp(distribution.START() + VESTING);
        uint256[] memory ids = new uint256[](0);
        vm.recordLogs();
        vm.prank(bob);
        assertEq(distribution.claim(ids), 0);
        assertEq(distribution.claimableFor(bob, ids), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_fullyClaimedIdsAreSkippedAlongsideNewClaims() public {
        vm.warp(distribution.START() + VESTING);
        vm.prank(alice);
        distribution.claim(_ids(1));
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 1;
        vm.prank(alice);
        assertEq(distribution.claim(ids), SHARE);
        assertEq(token.balanceOf(alice), SHARE * 2);
    }

    function test_wrongHolderRevertsIncludingAtStartAndAfterFullClaim() public {
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 1));
        vm.prank(bob);
        distribution.claim(_ids(1));
        vm.warp(distribution.START() + VESTING);
        vm.prank(alice);
        distribution.claim(_ids(1));
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 1));
        vm.prank(bob);
        distribution.claim(_ids(1));
    }

    function test_unclaimedVestingMovesWithNftWithoutResettingSchedule() public {
        vm.warp(distribution.START() + 5 days);
        vm.prank(alice);
        pfp.transferFrom(alice, bob, 1);
        assertEq(distribution.holderOf(1), bob);
        assertEq(distribution.claimableFor(alice, _ids(1)), 0);
        assertEq(distribution.claimableFor(bob, _ids(1)), SHARE / 4);
        vm.prank(bob);
        assertEq(distribution.claim(_ids(1)), SHARE / 4);
        assertEq(token.balanceOf(bob), SHARE / 4);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_claimedAccountingSurvivesSaleAndTransferBack() public {
        uint256 start = distribution.START();
        vm.warp(start + 4 days);
        vm.prank(alice);
        uint256 alicePaid = distribution.claim(_ids(1));
        vm.prank(alice);
        pfp.transferFrom(alice, bob, 1);
        vm.warp(start + 10 days);
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 1));
        vm.prank(alice);
        distribution.claim(_ids(1));
        vm.prank(bob);
        uint256 bobPaid = distribution.claim(_ids(1));
        assertEq(bobPaid, SHARE / 2 - alicePaid);
        vm.prank(bob);
        pfp.transferFrom(bob, alice, 1);
        vm.warp(start + VESTING);
        vm.prank(alice);
        distribution.claim(_ids(1));
        assertEq(distribution.claimed(1), SHARE);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), SHARE);
    }

    function test_approvedOperatorCannotClaim() public {
        vm.prank(alice);
        pfp.approve(bob, 1);
        vm.prank(alice);
        pfp.setApprovalForAll(bob, true);
        vm.warp(distribution.START() + VESTING);
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 1));
        vm.prank(bob);
        distribution.claim(_ids(1));
    }

    function test_lockedNftPaysBeneficialHolderThenUnlockedSaleChangesHolder() public {
        vm.prank(alice);
        pfp.lock(1, 123);
        assertEq(pfp.ownerOf(1), address(pfp));
        assertEq(distribution.holderOf(1), alice);
        vm.warp(distribution.START() + 10 days);
        assertEq(distribution.claimableFor(alice, _ids(1)), SHARE / 2);
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 1));
        vm.prank(address(pfp));
        distribution.claim(_ids(1));
        vm.prank(alice);
        distribution.claim(_ids(1));
        assertEq(pfp.ownerOf(1), address(pfp));
        (address lockedHolder, uint32 betaId) = pfp.tokenLocks(1);
        assertEq(lockedHolder, alice);
        assertEq(betaId, 123);
        vm.prank(alice);
        pfp.unlock(1);
        vm.prank(alice);
        pfp.transferFrom(alice, bob, 1);
        vm.warp(distribution.START() + VESTING);
        vm.prank(bob);
        assertEq(distribution.claim(_ids(1)), SHARE - SHARE / 2);
        assertEq(distribution.claimed(1), SHARE);
    }

    function test_directOwnerTakesPrecedenceOverStaleLockAndFailingLockLookup() public {
        pfp.setLock(1, bob, 1);
        pfp.setFailLockLookup(true);
        assertEq(distribution.holderOf(1), alice);
        vm.warp(distribution.START() + VESTING);
        vm.prank(alice);
        assertEq(distribution.claim(_ids(1)), SHARE);
    }

    function test_lockedWithoutHolderIsUnclaimable() public {
        vm.prank(alice);
        pfp.transferFrom(alice, address(pfp), 1);
        vm.warp(distribution.START() + VESTING);
        assertEq(distribution.holderOf(1), address(0));
        assertEq(distribution.claimableFor(address(0), _ids(1)), 0);
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 1));
        vm.prank(alice);
        distribution.claim(_ids(1));
    }

    function test_failedLockLookupRevertsWithoutPayingOrUpdatingAccounting() public {
        vm.prank(alice);
        pfp.lock(2, 1);
        pfp.setFailLockLookup(true);
        vm.warp(distribution.START() + VESTING);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vm.expectRevert(MockPFP.LockLookupFailed.selector);
        vm.prank(alice);
        distribution.claim(ids);
        assertEq(distribution.claimed(1), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_burnedIdsHaveNoHolderAndCannotPayEvenWithStaleLock() public {
        vm.warp(distribution.START() + 10 days);
        vm.prank(alice);
        distribution.claim(_ids(1));
        pfp.setLock(1, alice, 1);
        pfp.burn(1);
        vm.warp(distribution.START() + VESTING);
        assertEq(distribution.holderOf(1), address(0));
        assertEq(distribution.claimed(1), SHARE / 2);
        assertEq(distribution.claimable(1), SHARE - SHARE / 2);
        assertEq(distribution.claimableFor(alice, _ids(1)), 0);
        assertEq(distribution.claimableFor(address(0), _ids(1)), 0);
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 1));
        vm.prank(alice);
        distribution.claim(_ids(1));
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 1));
        vm.prank(address(0));
        distribution.claim(_ids(1));
    }

    function test_unauthorizedLaterIdRevertsWholeBatch() public {
        vm.prank(alice);
        pfp.transferFrom(alice, bob, 2);
        vm.warp(distribution.START() + VESTING);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vm.expectRevert(abi.encodeWithSelector(HolderClaim.NotHolder.selector, 2));
        vm.prank(alice);
        distribution.claim(ids);
        assertEq(distribution.claimed(1), 0);
        assertEq(distribution.claimed(2), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(distribution)), ALLOCATION);
    }

    function test_claimableForFiltersOwnersAndBurnsAndDeduplicates() public {
        vm.prank(alice);
        pfp.transferFrom(alice, bob, 2);
        pfp.burn(3);
        vm.prank(alice);
        pfp.lock(4, 1);
        vm.warp(distribution.START() + VESTING);
        uint256[] memory ids = new uint256[](7);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        ids[3] = 4;
        ids[4] = 1;
        ids[5] = 111;
        ids[6] = 4;
        assertEq(distribution.claimableFor(alice, ids), SHARE * 3);
        assertEq(distribution.claimableFor(bob, ids), SHARE);
        assertEq(distribution.claimableFor(address(pfp), ids), 0);
        assertEq(distribution.claimableFor(address(0), ids), 0);
        assertEq(distribution.claimed(1), 0);
        vm.prank(alice);
        distribution.claim(_ids(4));
        assertEq(distribution.claimableFor(alice, ids), SHARE * 2);
    }

    function test_claimAllLeavesOnlyDivisionDustAndExtraDepositsLocked() public {
        uint256 extra = 7e18;
        token.transfer(address(distribution), extra);
        vm.warp(distribution.START() + VESTING);
        uint256[] memory ids = new uint256[](111);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(alice);
        assertEq(distribution.claim(ids), SHARE * 111);
        assertEq(token.balanceOf(alice), SHARE * 111);
        assertEq(token.balanceOf(address(distribution)), ALLOCATION % 111 + extra);
        vm.warp(distribution.START() + 1000 days);
        vm.prank(alice);
        assertEq(distribution.claim(ids), 0);
        assertEq(token.balanceOf(address(distribution)), ALLOCATION % 111 + extra);
    }

    function test_burnedAndUnclaimedAllocationsStayLockedAfterVestingEnds() public {
        pfp.burn(1);
        vm.warp(distribution.START() + VESTING + 365 days);
        uint256[] memory ids = new uint256[](109);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = i + 3;
        }
        vm.prank(alice);
        assertEq(distribution.claim(ids), SHARE * 109);
        assertEq(token.balanceOf(address(distribution)), SHARE * 2 + ALLOCATION % 111);
        // ID 2's holder can still claim later; ID 1's burned share has no recipient.
        assertEq(distribution.claimable(2), SHARE);
        assertEq(distribution.claimed(1), 0);
    }

    function test_insufficientFundingRevertsAllAccountingAndCanRetryAfterFunding() public {
        HolderClaim underfunded = new HolderClaim(address(token));
        vm.warp(underfunded.START() + VESTING);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        token.transfer(address(underfunded), SHARE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(underfunded), SHARE, SHARE * 2
            )
        );
        vm.prank(alice);
        underfunded.claim(ids);
        assertEq(underfunded.claimed(1), 0);
        assertEq(underfunded.claimed(2), 0);
        assertEq(token.balanceOf(alice), 0);
        token.transfer(address(underfunded), SHARE);
        vm.prank(alice);
        assertEq(underfunded.claim(ids), SHARE * 2);
    }

    function test_noAdminOrRecoveryEntryPoints() public {
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("withdraw(address,uint256)", alice, ALLOCATION);
        calls[2] = abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(token), alice, ALLOCATION);
        calls[3] = abi.encodeWithSignature("setToken(address)", address(token));
        calls[4] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[7] = abi.encodeWithSignature("setStart(uint256)", 0);
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(distribution).call(calls[i]);
            assertFalse(success);
        }
        assertEq(token.balanceOf(address(distribution)), ALLOCATION);
    }

    function testFuzz_invalidIdsRevertAcrossViewsAndAtomicClaim(uint256 invalid) public {
        if (invalid >= 1 && invalid <= 111) invalid = 0;
        bytes memory expected = abi.encodeWithSelector(HolderClaim.InvalidId.selector, invalid);
        vm.expectRevert(expected);
        distribution.vested(invalid);
        vm.expectRevert(expected);
        distribution.holderOf(invalid);
        vm.expectRevert(expected);
        distribution.claimable(invalid);
        vm.expectRevert(expected);
        distribution.claimableFor(alice, _ids(invalid));

        vm.warp(distribution.START() + VESTING);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = invalid;
        vm.expectRevert(expected);
        vm.prank(alice);
        distribution.claim(ids);
        assertEq(distribution.claimed(1), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_splitClaimsAndSaleConserveOneShare(uint32 first, uint32 second, uint8 rawId) public {
        uint256 id = bound(rawId, 1, 111);
        uint256 t1 = bound(first, 0, VESTING);
        uint256 t2 = bound(second, t1, VESTING * 2);
        uint256 start = distribution.START();
        vm.warp(start + t1);
        vm.prank(alice);
        uint256 firstPaid = distribution.claim(_ids(id));
        assertEq(firstPaid, SHARE * t1 / VESTING);
        vm.prank(alice);
        pfp.transferFrom(alice, bob, id);
        vm.warp(start + t2);
        vm.prank(bob);
        uint256 secondPaid = distribution.claim(_ids(id));
        assertEq(firstPaid + secondPaid, SHARE * (t2 > VESTING ? VESTING : t2) / VESTING);
        vm.warp(start + VESTING * 2);
        vm.prank(bob);
        distribution.claim(_ids(id));
        assertEq(distribution.claimed(id), SHARE);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), SHARE);
    }

    function testFuzz_duplicateBatchMatchesUniquePreview(uint8[] memory rawIds, uint32 elapsed) public {
        uint256[] memory ids = new uint256[](bound(rawIds.length, 0, 160));
        bool[112] memory seen;
        uint256 count;
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = uint256(rawIds[i]) % 111 + 1;
            if (!seen[ids[i]]) {
                seen[ids[i]] = true;
                ++count;
            }
        }
        uint256 duration = bound(elapsed, 0, VESTING * 2);
        vm.warp(distribution.START() + duration);
        uint256 expected = count * (SHARE * (duration > VESTING ? VESTING : duration) / VESTING);
        assertEq(distribution.claimableFor(alice, ids), expected);
        vm.prank(alice);
        assertEq(distribution.claim(ids), expected);
        assertEq(token.balanceOf(alice), expected);
        assertEq(distribution.claimableFor(alice, ids), 0);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
