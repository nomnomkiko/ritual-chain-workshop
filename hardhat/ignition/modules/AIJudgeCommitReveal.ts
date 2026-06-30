import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Ignition deployment module for AIJudgeCommitReveal.
 *
 * Deploy with:
 *   pnpm hardhat ignition deploy ignition/modules/AIJudgeCommitReveal.ts --network ritual
 */
const AIJudgeCommitRevealModule = buildModule("AIJudgeCommitRevealModule", (m) => {
  const aiJudge = m.contract("AIJudgeCommitReveal");
  return { aiJudge };
});

export default AIJudgeCommitRevealModule;
