// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HolderClaim} from "../../src/HolderClaim.sol";

interface ITokenCallback {
    function onTokenTransfer() external;
}

/// @dev Test-only token for external-call failure and callback paths. This is not PIC.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        FalseReturn,
        Revert,
        NoReturn,
        InvalidReturn,
        Callback
    }

    Mode public mode;
    uint256 public transferCalls;

    error TransferRejected();

    constructor() ERC20("Adversarial test token", "TEST") {
        _mint(msg.sender, 800_000_000e18);
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        ++transferCalls;
        if (mode == Mode.Revert) revert TransferRejected();
        super.transfer(to, amount);
        if (mode == Mode.FalseReturn) return false;
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == Mode.InvalidReturn) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (mode == Mode.Callback) ITokenCallback(to).onTokenTransfer();
        return true;
    }
}

contract ReenteringHolder is ITokenCallback {
    HolderClaim public immutable distribution;
    address public immutable token;
    uint256 public callbacks;
    bool public reentered;
    bytes public failure;
    uint256 public observedClaimed1;
    uint256 public observedClaimed2;
    uint256 public observedClaimable;

    constructor(HolderClaim distribution_, address token_) {
        distribution = distribution_;
        token = token_;
    }

    function startClaim() external returns (uint256) {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        return distribution.claim(ids);
    }

    function onTokenTransfer() external {
        require(msg.sender == token, "wrong token");
        ++callbacks;
        observedClaimed1 = distribution.claimed(1);
        observedClaimed2 = distribution.claimed(2);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        observedClaimable = distribution.claimableFor(address(this), ids);
        (reentered, failure) = address(distribution).call(abi.encodeCall(distribution.claim, (ids)));
    }
}
