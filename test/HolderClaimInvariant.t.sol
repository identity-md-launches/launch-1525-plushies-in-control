// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PICToken} from "../src/PICToken.sol";
import {HolderClaim} from "../src/HolderClaim.sol";
import {MockPFP} from "./mocks/MockPFP.sol";

/// @dev Independent accounting and ownership model driven by randomized actions.
contract ClaimHandler is Test {
    uint256 internal constant SHARE = uint256(800_000_000e18) / 111;
    HolderClaim public immutable distribution;
    MockPFP public immutable pfp;
    PICToken public immutable token;
    address[4] public actors;
    mapping(uint256 => address) public expectedHolder;
    mapping(uint256 => bool) public locked;
    mapping(uint256 => uint256) public expectedClaimed;
    mapping(address => uint256) public expectedPaid;
    uint256 public totalPaid;
    uint256 public totalDonated;
    uint256 public rejectedClaims;

    constructor(HolderClaim distribution_, MockPFP pfp_, address[4] memory actors_) {
        distribution = distribution_;
        pfp = pfp_;
        token = PICToken(address(distribution_.token()));
        actors = actors_;
        for (uint256 id = 1; id <= 111; ++id) {
            expectedHolder[id] = actors_[0];
        }
    }

    function advanceTime(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 3 days));
    }

    function transferNft(uint8 rawId, uint8 rawActor) external {
        uint256 id = uint256(rawId) % 111 + 1;
        address from = expectedHolder[id];
        if (from == address(0)) return;
        address to = actors[uint256(rawActor) % actors.length];
        if (locked[id]) {
            vm.prank(from);
            pfp.unlock(id);
            locked[id] = false;
        }
        vm.prank(from);
        pfp.transferFrom(from, to, id);
        expectedHolder[id] = to;
    }

    function toggleLock(uint8 rawId) external {
        uint256 id = uint256(rawId) % 111 + 1;
        address holder = expectedHolder[id];
        if (holder == address(0)) return;
        vm.prank(holder);
        if (locked[id]) pfp.unlock(id);
        else pfp.lock(id, 1);
        locked[id] = !locked[id];
    }

    function burnNft(uint8 rawId) external {
        uint256 id = uint256(rawId) % 111 + 1;
        if (expectedHolder[id] == address(0)) return;
        pfp.burn(id);
        expectedHolder[id] = address(0);
        locked[id] = false;
    }

    function claimOne(uint8 rawId, bool duplicate) external {
        uint256 id = uint256(rawId) % 111 + 1;
        address holder = expectedHolder[id];
        if (holder == address(0)) return;
        uint256[] memory ids = new uint256[](duplicate ? 3 : 1);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = id;
        }
        uint256 unlocked = _unlocked();
        uint256 expected = unlocked - expectedClaimed[id];
        assertEq(distribution.claimableFor(holder, ids), expected);
        vm.prank(holder);
        assertEq(distribution.claim(ids), expected);
        expectedClaimed[id] = unlocked;
        expectedPaid[holder] += expected;
        totalPaid += expected;
    }

    function claimBatch(uint8 rawActor) external {
        address holder = actors[uint256(rawActor) % actors.length];
        uint256 count;
        for (uint256 id = 1; id <= 111; ++id) {
            if (expectedHolder[id] == holder) ++count;
        }
        uint256[] memory ids = new uint256[](count);
        uint256 expected;
        uint256 cursor;
        uint256 unlocked = _unlocked();
        for (uint256 id = 1; id <= 111; ++id) {
            if (expectedHolder[id] != holder) continue;
            ids[cursor++] = id;
            expected += unlocked - expectedClaimed[id];
            expectedClaimed[id] = unlocked;
        }
        assertEq(distribution.claimableFor(holder, ids), expected);
        vm.prank(holder);
        assertEq(distribution.claim(ids), expected);
        expectedPaid[holder] += expected;
        totalPaid += expected;
    }

    /// @dev Model deposits separately: they must never increase an ID's entitlement.
    function donate(uint256 amount) external {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        assertTrue(token.transfer(address(distribution), amount));
        totalDonated += amount;
    }

    function claimAsNonHolder(uint8 rawId, uint8 rawActor) external {
        uint256 id = bound(rawId, 1, 111);
        uint256 actorIndex = uint256(rawActor) % actors.length;
        if (actors[actorIndex] == expectedHolder[id]) actorIndex = (actorIndex + 1) % actors.length;
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        _reject(actors[actorIndex], ids, abi.encodeWithSelector(HolderClaim.NotHolder.selector, id));
    }

    /// @dev Exercise rollback after a valid, potentially payable prefix and a duplicate.
    function claimWithInvalidSuffix(uint8 rawId, uint256 rawInvalid) external {
        uint256 id = bound(rawId, 1, 111);
        address holder = expectedHolder[id];
        if (holder == address(0)) return;
        uint256 invalid = rawInvalid == 0 ? 0 : bound(rawInvalid, 112, type(uint256).max);
        uint256[] memory ids = new uint256[](3);
        ids[0] = id;
        ids[1] = id;
        ids[2] = invalid;
        _reject(holder, ids, abi.encodeWithSelector(HolderClaim.InvalidId.selector, invalid));
    }

    function claimWithForeignSuffix(uint8 rawId, uint8 rawOffset) external {
        uint256 id = bound(rawId, 1, 111);
        address holder = expectedHolder[id];
        if (holder == address(0)) return;
        // Find a foreign or burned ID without mutating ownership to manufacture a failure.
        for (uint256 i; i < 111; ++i) {
            uint256 other = (uint256(rawOffset) + i) % 111 + 1;
            if (expectedHolder[other] == holder) continue;
            uint256[] memory ids = new uint256[](4);
            ids[0] = id;
            ids[1] = id;
            ids[2] = other;
            ids[3] = id;
            _reject(holder, ids, abi.encodeWithSelector(HolderClaim.NotHolder.selector, other));
            return;
        }
    }

    /// @dev Failed calls must preserve the model, including claims made in earlier transactions.
    function _reject(address caller, uint256[] memory ids, bytes memory reason) private {
        uint256 beforeBalance = token.balanceOf(address(distribution));
        uint256 callerBalance = token.balanceOf(caller);
        vm.expectRevert(reason);
        vm.prank(caller);
        distribution.claim(ids);
        assertEq(token.balanceOf(address(distribution)), beforeBalance, "failed batch spent PIC");
        assertEq(token.balanceOf(caller), callerBalance, "failed batch paid caller");
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] >= 1 && ids[i] <= 111) {
                assertEq(distribution.claimed(ids[i]), expectedClaimed[ids[i]], "failed batch changed claimed");
            }
        }
        ++rejectedClaims;
    }

    function _unlocked() private view returns (uint256) {
        uint256 elapsed = block.timestamp - distribution.START();
        return SHARE * (elapsed > 20 days ? 20 days : elapsed) / 20 days;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract HolderClaimInvariantTest is StdInvariant, Test {
    uint256 internal constant ALLOCATION = 800_000_000e18;
    uint256 internal constant SHARE = ALLOCATION / 111;
    PICToken internal token;
    HolderClaim internal distribution;
    ClaimHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        vm.warp(1_800_000_000);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        token = new PICToken();
        distribution = new HolderClaim(address(token));
        vm.etch(distribution.PFP(), address(new MockPFP()).code);
        MockPFP pfp = MockPFP(distribution.PFP());
        pfp.initialize(actors[0]);
        token.transfer(address(distribution), ALLOCATION);
        handler = new ClaimHandler(distribution, pfp, actors);
        // A finite real PIC reserve funds donations; no balance cheatcodes or new minting.
        token.transfer(address(handler), token.balanceOf(address(this)));

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ClaimHandler.advanceTime.selector;
        selectors[1] = ClaimHandler.transferNft.selector;
        selectors[2] = ClaimHandler.toggleLock.selector;
        selectors[3] = ClaimHandler.burnNft.selector;
        selectors[4] = ClaimHandler.claimOne.selector;
        selectors[5] = ClaimHandler.claimBatch.selector;
        selectors[6] = ClaimHandler.donate.selector;
        selectors[7] = ClaimHandler.claimAsNonHolder.selector;
        selectors[8] = ClaimHandler.claimWithInvalidSuffix.selector;
        selectors[9] = ClaimHandler.claimWithForeignSuffix.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_scheduleOwnershipAndConservation() public view {
        uint256 elapsed = block.timestamp - distribution.START();
        uint256 vested = SHARE * (elapsed > 20 days ? 20 days : elapsed) / 20 days;
        uint256 accounted;
        for (uint256 id = 1; id <= 111; ++id) {
            uint256 paid = distribution.claimed(id);
            assertEq(paid, handler.expectedClaimed(id));
            assertLe(paid, vested);
            assertEq(distribution.vested(id), vested);
            assertEq(distribution.claimable(id), vested - paid);
            assertEq(distribution.holderOf(id), handler.expectedHolder(id));
            accounted += paid;
        }
        uint256 received;
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.expectedPaid(actors[i]));
            received += balance;
        }
        assertEq(accounted, received);
        assertEq(accounted, handler.totalPaid());
        assertLe(accounted, SHARE * 111);
        assertEq(token.balanceOf(address(distribution)) + received, ALLOCATION + handler.totalDonated());
        assertEq(token.balanceOf(address(handler)) + handler.totalDonated(), 200_000_000e18);
        assertEq(
            token.balanceOf(address(distribution)) + received + token.balanceOf(address(handler)), 1_000_000_000e18
        );
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    /// @dev Every surviving ID can finish after any random history, including histories of failures.
    function afterInvariant() public {
        uint256 end = distribution.START() + 20 days;
        if (vm.getBlockTimestamp() < end) vm.warp(end);
        for (uint8 i; i < actors.length; ++i) {
            handler.claimBatch(i);
            // Repeated settlement at the same time must remain harmless.
            handler.claimBatch(i);
        }
        invariant_scheduleOwnershipAndConservation();
        uint256 burnedRemainder;
        for (uint256 id = 1; id <= 111; ++id) {
            if (handler.expectedHolder(id) == address(0)) {
                burnedRemainder += SHARE - handler.expectedClaimed(id);
            } else {
                assertEq(distribution.claimed(id), SHARE, "surviving ID could not finish");
            }
        }
        assertEq(
            token.balanceOf(address(distribution)),
            burnedRemainder + ALLOCATION % 111 + handler.totalDonated(),
            "only burned shares, donations and division dust should remain"
        );
    }

    /// @dev Pin a non-vacuous handler sequence in addition to the randomized campaign.
    function test_handlerSequenceIncludesFailuresDonationsLocksAndBurns() public {
        handler.advanceTime(1 days);
        handler.claimOne(0, true); // ID 1 already has nonzero cumulative accounting.
        handler.transferNft(1, 1); // ID 2 moves to actor 1.
        handler.toggleLock(1);
        handler.advanceTime(1 days);
        handler.claimWithForeignSuffix(1, 1);
        handler.claimWithInvalidSuffix(1, type(uint256).max);
        handler.claimAsNonHolder(1, 0);
        assertEq(handler.rejectedClaims(), 3);
        handler.donate(1);
        handler.burnNft(0);
        invariant_scheduleOwnershipAndConservation();
        afterInvariant();
    }
}
