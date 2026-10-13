# PIC test coverage

Run `forge build` and `forge test`. All dependencies are already vendored. The tests
use the real `PICToken` and `HolderClaim`, plus the existing PFP mock at the specified
mainnet address. They require no RPC, fork, environment variables, or network.

The existing example and security tests cover constructor constants, launch
allocation, authorization, NFT sales, lock lookup failures, burned IDs, invalid IDs,
duplicate claims, reentrancy, failing token transfers, and absence of common admin
entry points.

The additional coverage is organized as follows:

| Suite | Properties |
| --- | --- |
| `HolderClaimProperties.t.sol` | Arbitrary claim frequency preserves entitlement; reversing and splitting a duplicate batch preserves payouts and per-ID state after earlier partial claims; rational floor bounds define vesting; one-wei underfunding rolls back existing and new claim records; exact indexed events and one aggregate transfer; NFT approvals and lock records survive claims. |
| `HolderClaimInvariant.t.sol` | Four actors randomly claim, transfer, lock, unlock, burn, donate, and submit unauthorized/invalid batches. The independent model checks per-ID payments, holders, actor balances, fixed supply, and conservation including donations. After each campaign, every surviving ID must settle completely; only burned remainders, donations, and division dust remain. |
| `PICTokenInvariant.t.sol` | Four actors randomly transfer, approve, spend allowances, revoke, and try invalid transfers. An independent ledger checks every balance and allowance, including self-transfers, infinite approvals, and rollback of allowance spending after a balance failure. |

Inline settings run each new stateless property 1,000 times, the HolderClaim invariant
256 times at depth 80, and the PIC invariant 256 times at depth 96. Unexpected handler
reverts fail the campaigns; expected errors are checked explicitly. Deterministic
handler sequences pin successful operations and rejected operations so those paths
are exercised even when a random sequence does not select them.

PIC donations are funded from the original supply. No token balances or claim records
are fabricated using storage or balance cheatcodes. PFP burns and lock transitions
use the existing mock controls. These tests establish local accounting and eligibility
behavior; the supplied launch verifier owns the actual pool integration checks.
