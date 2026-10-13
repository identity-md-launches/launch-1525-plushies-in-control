// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Plushies In Control
/// @notice Fixed supply, 18-decimal ERC-20. The launch factory receives the entire supply on deployment.
contract PICToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("Plushies In Control", "PIC") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
