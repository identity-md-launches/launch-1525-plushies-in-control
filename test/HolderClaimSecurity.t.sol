// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HolderClaim} from "../src/HolderClaim.sol";
import {MockPFP} from "./mocks/MockPFP.sol";
import {AdversarialToken, ReenteringHolder} from "./mocks/AdversarialToken.sol";

contract HolderClaimSecurityTest is Test {
    uint256 internal constant ALLOCATION = 800_000_000e18;
    uint256 internal constant SHARE = ALLOCATION / 111;

    AdversarialToken internal token;
    HolderClaim internal distribution;
    MockPFP internal pfp;
    address internal alice;

    function setUp() public {
        vm.warp(1_800_000_000);
        alice = makeAddr("alice");
        token = new AdversarialToken();
        distribution = new HolderClaim(address(token));
        vm.etch(distribution.PFP(), address(new MockPFP()).code);
        pfp = MockPFP(distribution.PFP());
        pfp.initialize(alice);
        token.transfer(address(distribution), ALLOCATION);
        vm.warp(distribution.START() + 20 days);
    }

    function test_falseReturnRollsBackAllAccountingAndTokenState() public {
        token.setMode(AdversarialToken.Mode.FalseReturn);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(alice);
        distribution.claim(_batch());
        _assertRolledBack();
        token.setMode(AdversarialToken.Mode.Normal);
        vm.prank(alice);
        assertEq(distribution.claim(_batch()), SHARE * 2);
    }

    function test_revertingTransferBubblesErrorAndRollsBack() public {
        token.setMode(AdversarialToken.Mode.Revert);
        vm.expectRevert(AdversarialToken.TransferRejected.selector);
        vm.prank(alice);
        distribution.claim(_batch());
        _assertRolledBack();
    }

    function test_invalidReturnRollsBack() public {
        token.setMode(AdversarialToken.Mode.InvalidReturn);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(alice);
        distribution.claim(_batch());
        _assertRolledBack();
    }

    function test_noReturnTokenWorksAndOnlyOneTransferIsUsed() public {
        token.setMode(AdversarialToken.Mode.NoReturn);
        uint256 callsBefore = token.transferCalls();
        vm.prank(alice);
        assertEq(distribution.claim(_batch()), SHARE * 2);
        assertEq(token.balanceOf(alice), SHARE * 2);
        assertEq(token.transferCalls(), callsBefore + 1);
        assertEq(distribution.claimed(1), SHARE);
        assertEq(distribution.claimed(2), SHARE);
    }

    function test_zeroPayoutNeverCallsToken() public {
        vm.prank(alice);
        distribution.claim(_batch());
        token.setMode(AdversarialToken.Mode.Revert);
        uint256 callsBefore = token.transferCalls();
        vm.prank(alice);
        assertEq(distribution.claim(_batch()), 0);
        assertEq(token.transferCalls(), callsBefore);
    }

    function test_tokenWithoutCodeCannotConsumeClaim() public {
        address noCode = makeAddr("no token code");
        HolderClaim missingToken = new HolderClaim(noCode);
        vm.warp(missingToken.START() + 20 days);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, noCode));
        vm.prank(alice);
        missingToken.claim(_batch());
        assertEq(missingToken.claimed(1), 0);
        assertEq(missingToken.claimed(2), 0);
    }

    function test_reentryBlockedAndAllBatchEffectsVisibleBeforeTransfer() public {
        ReenteringHolder receiver = new ReenteringHolder(distribution, address(token));
        for (uint256 id = 1; id <= 3; ++id) {
            vm.prank(alice);
            pfp.transferFrom(alice, address(receiver), id);
        }
        token.setMode(AdversarialToken.Mode.Callback);
        assertEq(receiver.startClaim(), SHARE * 2);
        assertEq(receiver.callbacks(), 1);
        assertFalse(receiver.reentered());
        assertEq(receiver.failure(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(receiver.observedClaimed1(), SHARE);
        assertEq(receiver.observedClaimed2(), SHARE);
        assertEq(receiver.observedClaimable(), SHARE);
        assertEq(token.balanceOf(address(receiver)), SHARE * 2);
        assertEq(distribution.claimed(3), 0);
        assertEq(pfp.ownerOf(1), address(receiver));
        assertEq(pfp.ownerOf(2), address(receiver));
        assertEq(receiver.startClaim(), 0);
        assertEq(receiver.callbacks(), 1);
    }

    function _assertRolledBack() private view {
        assertEq(distribution.claimed(1), 0);
        assertEq(distribution.claimed(2), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(distribution)), ALLOCATION);
        assertEq(token.transferCalls(), 1);
    }

    function _batch() private pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 1;
    }
}
