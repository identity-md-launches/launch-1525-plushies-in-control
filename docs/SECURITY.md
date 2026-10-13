# Security review notes

This is a local implementation review, not an independent audit. An independent contributor's adversarial review and the launch network's protected checks remain release responsibilities. No transactions were broadcast.

## Scope and assumptions

The production surface is PICToken, HolderClaim, IFWAIRPFP, the internal-only LaunchEconomics library, and their inlined OpenZeppelin dependencies. Test mocks and the allocation harness are not launch artifacts. The Ethereum PFP address is fixed by the assignment. HolderClaim assumes its supplied token is this 18-decimal PIC implementation: rebasing, taxed, malicious, or differently denominated tokens are outside its intended use. The factory must choose the correct constructor argument and fund the full 800,000,000 PIC allocation atomically.

The fixed PFP contract controls NFT ownership and lock records. HolderClaim cannot correct those records or recover funds if the external dependency fails. The NFT's holder at transaction execution has the right to claim; ownership changes before transaction inclusion may invalidate a pending claim. Historical ownership or an NFT approval grants no rights. Timestamp rounding follows the prescribed per-second schedule, with no additional cliff or expiry.

## Reviewed properties

| Risk | Defense and test evidence |
| --- | --- |
| Unauthorized payout | Every supplied ID resolves to the caller, including zero-entitlement entries. Approved operators, prior owners, the PFP escrow address, and non-holders cannot collect. |
| Duplicate claims | Per-ID cumulative accounting is updated while iterating. Views use a 111-bit set to deduplicate the preview. Randomized duplicate arrays are checked against an independent unique-ID count. |
| Reentrancy | Ownership lookups are static calls. All effects precede a single token transfer; OpenZeppelin ReentrancyGuard blocks callbacks. A receiver holding multiple IDs tries to reenter during payout and observes already-updated accounting. |
| Failed payout | SafeERC20 checks transfer success and missing token code. Insufficient funding, false/invalid return values, and token reverts restore the complete batch and all balances. A funding retry succeeds. |
| Arithmetic or overpayment | Amounts use fixed 18-decimal units; multiply before dividing, cap elapsed time before multiplication, and never pay above SHARE. Fuzz tests and a stateful model check ownership, cumulative limits, balances, and fixed supply. |
| Burn/lock confusion | `ownerOf` reverts produce no holder. Lock records are consulted only while PFP owns the ID. Stale records do not override a direct owner or resurrect burned entitlement. |
| Loss from repeated rounding | Each payment is the difference of cumulative floors. Daily claims sum to a full SHARE. The total division remainder is 23 base units. |
| Privileged access or supply changes | No owner/admin/recovery/upgrades; mint occurs only in PICToken's constructor. Standard ERC-20 allowance checks still apply to the deployer. Tests probe common privileged selectors and require rejection. |
| Launch misallocation | The split is a source constant (`poolBps = 1000`, swarm 10%, remainder 80%) and `HolderClaim.ALLOCATION` reads it. The contracts cannot force the factory to pay; `fundingShortfall()`/`isFunded()` make an underfunded launch visible on chain, and tests show the earlier 88% pool economics and a wallet-routed remainder both leave HolderClaim unable to pay full shares. The views only read `claimed` and the balance and give no one a withdrawal or funding power. |
| Unbounded enumeration | Caller-supplied arrays cost gas proportional to their length. There are only 111 eligible unique IDs; a test claims all in one batch. No global holder scan, keeper, oracle, or exchange integration exists in the contracts. |

Burned shares, unclaimed balances, excess PIC, and other assets cannot be withdrawn through a recovery path. These are intentional restrictions, not unfinished administrative features.

## Local verification

The project uses Foundry unit tests, 512 runs per fuzz test, and a stateful invariant campaign of 128 runs with depth 64. The invariant handler models holders and payments independently and combines time progression, repeated claims, transfers, locking/unlocking, and burns. Tests use no fork, environment configuration, or external RPC.

`forge build`, `forge test`, and `forge fmt --check` are the required verification commands. Foundry lint findings about timestamps, external reads inside loops, validation reverts inside loops, and an unused `betaId` return are expected from the requested design: timestamps define vesting, each ID needs live ownership validation, invalid batches must revert, and lock beta numbers have no bearing on eligibility. Slither and Mythril were not run. Passing local tests does not claim production pool integration or independent audit coverage.
