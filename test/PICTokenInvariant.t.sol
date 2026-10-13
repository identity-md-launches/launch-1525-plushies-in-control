// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PICToken} from "src/PICToken.sol";

/// @dev Keep a closed set of wallets so every unit of PIC and every allowance is accounted for.
contract PICTokenHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    PICToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public successfulSpends;
    uint256 public rejectedSpends;

    constructor(PICToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = SUPPLY;
    }

    function transfer(uint8 rawFrom, uint8 rawTo, uint256 rawAmount) external {
        address from = actors[uint256(rawFrom) % actors.length];
        address to = actors[uint256(rawTo) % actors.length];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint8 rawOwner, uint8 rawSpender, uint256 rawAmount, bool infinite) external {
        address owner = actors[uint256(rawOwner) % actors.length];
        address spender = actors[uint256(rawSpender) % actors.length];
        uint256 amount = infinite ? type(uint256).max : bound(rawAmount, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    /// @dev Generate both payable transfers and exactly-one-unit-over-limit failures.
    function spend(uint8 rawOwner, uint8 rawSpender, uint8 rawTo, uint256 rawAmount, bool exceedLimit) external {
        address owner = actors[uint256(rawOwner) % actors.length];
        address spender = actors[uint256(rawSpender) % actors.length];
        address to = actors[uint256(rawTo) % actors.length];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 limit = allowed < balance ? allowed : balance;
        uint256 amount = exceedLimit ? limit + 1 : bound(rawAmount, 0, limit);
        if (exceedLimit) {
            if (amount > allowed) {
                vm.expectRevert(
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
                );
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
                );
            }
            vm.prank(spender);
            token.transferFrom(owner, to, amount);
            // In particular, a balance failure cannot spend an otherwise sufficient allowance.
            assertEq(token.allowance(owner, spender), allowed);
            assertEq(token.balanceOf(owner), balance);
            ++rejectedSpends;
        } else {
            vm.prank(spender);
            assertTrue(token.transferFrom(owner, to, amount));
            _move(owner, to, amount);
            if (allowed != type(uint256).max) expectedAllowance[owner][spender] = allowed - amount;
            ++successfulSpends;
        }
    }

    function rejectZeroReceiver(uint8 rawFrom, uint256 rawAmount) external {
        address from = actors[uint256(rawFrom) % actors.length];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(from), expectedBalance[from]);
    }

    function revokeThenTrySpend(uint8 rawOwner, uint8 rawSpender) external {
        address owner = actors[uint256(rawOwner) % actors.length];
        address spender = actors[uint256(rawSpender) % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, spender, 1);
        ++rejectedSpends;
    }

    function _move(address from, address to, uint256 amount) private {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PICTokenInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000e18;
    PICToken private token;
    PICTokenHandler private handler;
    address[4] private actors;

    function setUp() public {
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("PIC actor ", vm.toString(i)));
        }
        token = new PICToken();
        token.transfer(actors[0], SUPPLY);
        handler = new PICTokenHandler(token, actors);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PICTokenHandler.transfer.selector;
        selectors[1] = PICTokenHandler.approve.selector;
        selectors[2] = PICTokenHandler.spend.selector;
        selectors[3] = PICTokenHandler.rejectZeroReceiver.selector;
        selectors[4] = PICTokenHandler.revokeThenTrySpend.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesAndAllowancesMatchIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(actors[i]));
            sum += token.balanceOf(actors[i]);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j]));
            }
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function test_handlerSequencePinsFullSupplyInfiniteAllowanceAndFailedBalanceRollback() public {
        handler.transfer(0, 1, SUPPLY);
        handler.approve(1, 2, SUPPLY, false);
        handler.transfer(1, 3, SUPPLY - 1);
        handler.spend(1, 2, 0, 0, true); // Sufficient allowance, insufficient balance.
        assertEq(token.allowance(actors[1], actors[2]), SUPPLY);
        handler.approve(3, 2, 0, true);
        handler.spend(3, 2, 3, SUPPLY - 1, false); // Self transfer still checks allowance.
        handler.spend(3, 2, 0, SUPPLY - 1, false);
        assertEq(token.allowance(actors[3], actors[2]), type(uint256).max);
        handler.revokeThenTrySpend(3, 2);
        handler.rejectZeroReceiver(1, 1);
        assertEq(handler.successfulSpends(), 2);
        assertEq(handler.rejectedSpends(), 2);
        invariant_balancesAndAllowancesMatchIndependentLedger();
    }

    function test_finiteAllowanceIsConsumedBySelfTransferAndZeroSpenderCannotBeApproved() public {
        handler.approve(0, 1, 1, false);
        handler.spend(0, 1, 0, 1, false);
        assertEq(token.balanceOf(actors[0]), SUPPLY);
        assertEq(token.allowance(actors[0], actors[1]), 0);
        handler.spend(0, 1, 2, 0, true);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(actors[0]);
        token.approve(address(0), 1);
        invariant_balancesAndAllowancesMatchIndependentLedger();
    }
}
