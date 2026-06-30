# AI Bounty Judge — Privacy-Preserving Edition (Commit-Reveal)

Homework submission for **Ritual Academy Bootcamp #1**.
Forked from: https://github.com/cozfuttu/ritual-chain-workshop

## Problem Being Solved

In the original workshop contract, answers were stored **publicly on-chain
the moment they were submitted**. This let later participants read earlier
answers and submit improved copies before judging — unfair in a
winner-takes-all bounty.

This homework fixes that with a **commit-reveal** flow.

## New Contract

`hardhat/contracts/AIJudgeCommitReveal.sol`

## Bounty Lifecycle

```
 t=0                 submissionDeadline        revealDeadline
  │                          │                        │
  ├── COMMIT PHASE ──────────┤── REVEAL PHASE ─────────┤── JUDGE / FINALIZE ──▶
  │  submitCommitment()      │  revealAnswer()         │  judgeAll()
  │  (hash only, no answer   │  (answer + salt;        │  finalizeWinner()
  │   text stored on-chain)  │   contract verifies      │  (owner calls AI,
  │                          │   hash matches)          │   then confirms winner)
```

1. **Create Bounty** — owner calls `createBounty(title, rubric, submissionDeadline, revealDeadline)` with the reward as `msg.value`. `revealDeadline` must be after `submissionDeadline`.
2. **Commit Phase** — each participant computes off-chain:
   ```
   commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
   ```
   and calls `submitCommitment(bountyId, commitment)`. The plaintext answer never touches the chain at this point. One commitment per address per bounty.
3. **Reveal Phase** — after `submissionDeadline`, each participant calls `revealAnswer(bountyId, answer, salt)`. The contract recomputes the hash and only accepts the reveal if it matches. Unrevealed commitments are simply excluded from judging (and the reward stays with the bounty until finalized).
4. **Judge** — after `revealDeadline`, the owner calls `judgeAll(bountyId, llmInput)`. All revealed answers are batched into **one** LLM call via Ritual's LLM precompile (`0x0802`) — never one call per answer.
5. **Finalize** — the owner reviews the AI's `aiReview` recommendation and calls `finalizeWinner(bountyId, winnerIndex)`, which transfers the reward. This keeps a human in the loop in case the AI hallucinates.

## Why `msg.sender` and `bountyId` Are Inside the Hash

`keccak256(answer, salt, msg.sender, bountyId)` binds the commitment to a
specific person and a specific bounty. Without this, someone could observe
another participant's *commitment hash* (which is public) and, if they later
guessed or learned the answer+salt, falsely "reveal" it under their own
address. Binding `msg.sender` makes that reveal fail, since only the original
committer's address produces a matching hash.

## Deploying

```bash
cd hardhat
pnpm install
pnpm hardhat compile
pnpm hardhat keystore set DEPLOYER_PRIVATE_KEY
pnpm hardhat ignition deploy ignition/modules/AIJudgeCommitReveal.ts --network ritual
```

Fund the contract's Ritual Wallet balance (needed for the LLM precompile fee)
by calling `depositToRitualWallet()` with some testnet tokens before calling
`judgeAll()`.

## Files

- `hardhat/contracts/AIJudgeCommitReveal.sol` — main contract
- `hardhat/contracts/utils/PrecompileConsumer.sol` — Ritual-provided precompile helper
- `hardhat/ignition/modules/AIJudgeCommitReveal.ts` — deployment script
- `hardhat/test/AIJudgeCommitReveal.test.ts` — test suite
- `docs/ARCHITECTURE.md` — commit-reveal vs Ritual-native comparison
- `docs/REFLECTION.md` — answer to the reflection question

## Reflection

What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?

Public information should be limited to what's needed for trust and coordination without giving anyone a competitive edge: the bounty's existence, its rubric, its reward amount, and its deadlines should all be visible from the start, since participants need that to decide whether to compete. What should stay hidden is the actual content of submissions during the active competition window — answers, code, or designs — because exposing them early lets later entrants free-ride on earlier ideas, which undermines the entire point of a competitive bounty. Once the submission window closes and judging is complete, answers can reasonably become public again, both for transparency (so participants can verify the process was fair) and so the community can learn from the winning approach. As for AI versus human decision-making, AI is well suited to the mechanical, scalable part of judging — reading every submission against the rubric and producing a ranked, reasoned recommendation in one consistent pass — but it should not have unilateral authority to move funds, because LLMs can still hallucinate or be misled by adversarial submission text. A human (the bounty owner) should always confirm or override the AI's recommendation before the reward is actually paid out, keeping a human-in-the-loop checkpoint between "AI suggests" and "funds move."