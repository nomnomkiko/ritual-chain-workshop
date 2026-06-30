# Test Plan — AIJudgeCommitReveal

Full executable tests are in `hardhat/test/AIJudgeCommitReveal.test.ts`
(Hardhat + Chai + `@nomicfoundation/hardhat-network-helpers`).

`judgeAll()` calls a real Ritual precompile, which does not exist on a local
Hardhat network, so judging itself is verified manually on the live Ritual
testnet (see deployment section of README) — unit tests only check its
access-control guards (D1, D2 below). Everything else is fully unit-tested.

## A. `createBounty()`
| ID | Case | Expected |
|----|------|----------|
| A1 | Valid creation | Bounty stored correctly, event emitted |
| A2 | `msg.value == 0` | Reverts `"reward must be > 0"` |
| A3 | `submissionDeadline` in the past | Reverts |
| A4 | `revealDeadline <= submissionDeadline` | Reverts |

## B. `submitCommitment()`
| ID | Case | Expected |
|----|------|----------|
| B1 | Valid commitment during commit phase | Stored, event emitted, `hasCommitted == true` |
| B2 | Same address commits twice | Reverts `"already committed"` |
| B3 | Commit after `submissionDeadline` | Reverts `"submission phase has ended"` |

(Also implicitly covered by contract logic but worth manual review: max
10 submissions per bounty, enforced via `MAX_SUBMISSIONS`.)

## C. `revealAnswer()` — the core of commit-reveal correctness
| ID | Case | Expected |
|----|------|----------|
| C1 | Valid reveal after submission deadline | Submission added, event emitted, answer matches |
| C2 | Reveal attempted *before* `submissionDeadline` | Reverts `"reveal phase not started yet"` |
| C3 | Reveal with wrong `answer` text | Reverts `"commitment hash does not match"` |
| C4 | Reveal with wrong `salt` | Reverts `"commitment hash does not match"` |
| C5 | Same address reveals twice | Reverts `"already revealed"` |
| C6 | Reveal after `revealDeadline` | Reverts `"reveal phase has ended"` |
| C7 | Address that never committed tries to reveal | Reverts `"no commitment found for caller"` |
| C8 | Participant tries to reveal using someone else's answer/salt under their own address | Reverts (hash bound to `msg.sender`, won't match) |

## D. `judgeAll()` guard conditions (precompile mocked/skipped)
| ID | Case | Expected |
|----|------|----------|
| D1 | Called before `revealDeadline` | Reverts `"reveal phase not ended yet"` |
| D2 | Called by non-owner | Reverts `"not bounty owner"` |

**Manual/live-network checks for `judgeAll()`** (not unit-testable without a
real Ritual precompile):
- All revealed answers are concatenated into a single LLM prompt (not looped per answer).
- `hasError == false` path sets `judged = true` and stores `aiReview`.
- `hasError == true` path reverts with the precompile's error message.

## E. `finalizeWinner()`
| ID | Case | Expected |
|----|------|----------|
| E1 | Called before `judged == true` | Reverts `"bounty not judged yet"` |

(Additional cases validated by contract `require`s, recommended for extension:
double finalize, invalid `winnerIndex >= submissions.length`, non-owner caller.)

## F. `computeCommitment()` helper
| ID | Case | Expected |
|----|------|----------|
| F1 | On-chain hash matches off-chain `ethers.solidityPacked` + `keccak256` | Equal |

## Running

```bash
cd hardhat
pnpm install
pnpm hardhat test
```
