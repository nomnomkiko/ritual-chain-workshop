import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { keccak256, encodePacked, parseEther, zeroHash, getAddress } from "viem";

/**
 * Test plan for AIJudgeCommitReveal — Hardhat 3 + node:test + viem.
 *
 * judgeAll() requires a real Ritual LLM precompile, which does not exist on
 * a local simulated network, so it is NOT unit-tested here beyond its
 * access-control guards (D1, D2). Full judgeAll() behavior is verified
 * manually on the live Ritual testnet.
 *
 * Run with:  pnpm hardhat test
 */

/** Helper: compute the commitment hash exactly like the contract does */
function computeCommitment(
  answer: string,
  salt: `0x${string}`,
  sender: `0x${string}`,
  bountyId: bigint
): `0x${string}` {
  return keccak256(
    encodePacked(
      ["string", "bytes32", "address", "uint256"],
      [answer, salt, sender, bountyId]
    )
  );
}

describe("AIJudgeCommitReveal", async function () {
  const { viem, networkHelpers } = await network.connect();

  async function deployFixture() {
    const [owner, participant1, participant2, participant3] =
      await viem.getWalletClients();

    const aiJudge = await viem.deployContract("AIJudgeCommitReveal");

    const publicClient = await viem.getPublicClient();
    const now = Number((await publicClient.getBlock()).timestamp);
    const submissionDeadline = BigInt(now + 3600); // +1h
    const revealDeadline = BigInt(now + 7200); // +2h
    const reward = parseEther("1.0");

    return {
      aiJudge,
      owner,
      participant1,
      participant2,
      participant3,
      submissionDeadline,
      revealDeadline,
      reward,
      publicClient,
    };
  }

  // ── A. createBounty() ──────────────────────────────────────────────────
  await describe("A. createBounty()", async function () {
    await it("A1: creates a bounty with correct fields", async function () {
      const { aiJudge, owner, submissionDeadline, revealDeadline, reward } =
        await networkHelpers.loadFixture(deployFixture);

      await aiJudge.write.createBounty(
        ["Test Bounty", "Focus on correctness", submissionDeadline, revealDeadline],
        { value: reward, account: owner.account }
      );

      const b = await aiJudge.read.getBounty([0n]);
      assert.equal(getAddress(b[0]), getAddress(owner.account.address));
      assert.equal(b[1], "Test Bounty");
      assert.equal(b[3], reward);
      assert.equal(b[6], false); // judged
      assert.equal(b[7], false); // finalized
    });

    await it("A2: reverts if reward is zero", async function () {
      const { aiJudge, owner, submissionDeadline, revealDeadline } =
        await networkHelpers.loadFixture(deployFixture);

      await viem.assertions.revertWith(
        aiJudge.write.createBounty(
          ["Test", "Rubric", submissionDeadline, revealDeadline],
          { value: 0n, account: owner.account }
        ),
        "AIJudge: reward must be > 0"
      );
    });

    await it("A3: reverts if submissionDeadline is in the past", async function () {
      const { aiJudge, owner, revealDeadline, publicClient } =
        await networkHelpers.loadFixture(deployFixture);
      const now = Number((await publicClient.getBlock()).timestamp);
      const pastDeadline = BigInt(now - 1);

      await viem.assertions.revertWith(
        aiJudge.write.createBounty(
          ["Test", "Rubric", pastDeadline, revealDeadline],
          { value: parseEther("1"), account: owner.account }
        ),
        "AIJudge: submission deadline must be in the future"
      );
    });

    await it("A4: reverts if revealDeadline <= submissionDeadline", async function () {
      const { aiJudge, owner, submissionDeadline } =
        await networkHelpers.loadFixture(deployFixture);

      await viem.assertions.revertWith(
        aiJudge.write.createBounty(
          ["Test", "Rubric", submissionDeadline, submissionDeadline],
          { value: parseEther("1"), account: owner.account }
        ),
        "AIJudge: reveal deadline must be after submission deadline"
      );
    });
  });

  // ── B. submitCommitment() ──────────────────────────────────────────────
  await describe("B. submitCommitment()", async function () {
    async function bountyFixture() {
      const base = await deployFixture();
      await base.aiJudge.write.createBounty(
        ["Bounty", "Rubric", base.submissionDeadline, base.revealDeadline],
        { value: base.reward, account: base.owner.account }
      );
      return { ...base, bountyId: 0n };
    }

    await it("B1: accepts a valid commitment during the commit phase", async function () {
      const { aiJudge, participant1, bountyId } =
        await networkHelpers.loadFixture(bountyFixture);

      const answer = "Ritual is a blockchain with AI precompiles.";
      const salt = zeroHash;
      const commitment = computeCommitment(
        answer,
        salt,
        participant1.account.address,
        bountyId
      );

      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: participant1.account,
      });

      const committed = await aiJudge.read.hasCommitted([
        bountyId,
        participant1.account.address,
      ]);
      assert.equal(committed, true);
    });

    await it("B2: reverts on double commitment", async function () {
      const { aiJudge, participant1, bountyId } =
        await networkHelpers.loadFixture(bountyFixture);

      const commitment = computeCommitment(
        "answer",
        zeroHash,
        participant1.account.address,
        bountyId
      );
      await aiJudge.write.submitCommitment([bountyId, commitment], {
        account: participant1.account,
      });

      await viem.assertions.revertWith(
        aiJudge.write.submitCommitment([bountyId, commitment], {
          account: participant1.account,
        }),
        "AIJudge: already committed for this bounty"
      );
    });

    await it("B3: reverts if submission phase has ended", async function () {
      const { aiJudge, participant1, submissionDeadline, bountyId } =
        await networkHelpers.loadFixture(bountyFixture);

      await networkHelpers.time.increaseTo(submissionDeadline + 1n);
      const commitment = computeCommitment(
        "answer",
        zeroHash,
        participant1.account.address,
        bountyId
      );

      await viem.assertions.revertWith(
        aiJudge.write.submitCommitment([bountyId, commitment], {
          account: participant1.account,
        }),
        "AIJudge: submission phase has ended"
      );
    });
  });

  // ── C. revealAnswer() ──────────────────────────────────────────────────
  await describe("C. revealAnswer()", async function () {
    const ANSWER =
      "Ritual is the first blockchain where smart contracts can call LLMs.";
    const SALT = keccak256(encodePacked(["string"], ["my-secret-salt"]));

    async function committedFixture() {
      const base = await deployFixture();
      await base.aiJudge.write.createBounty(
        ["Bounty", "Rubric", base.submissionDeadline, base.revealDeadline],
        { value: base.reward, account: base.owner.account }
      );

      const bountyId = 0n;
      const commitment = computeCommitment(
        ANSWER,
        SALT,
        base.participant1.account.address,
        bountyId
      );
      await base.aiJudge.write.submitCommitment([bountyId, commitment], {
        account: base.participant1.account,
      });

      return { ...base, bountyId };
    }

    await it("C1: valid reveal succeeds and adds to submissions array", async function () {
      const { aiJudge, participant1, submissionDeadline, bountyId } =
        await networkHelpers.loadFixture(committedFixture);

      await networkHelpers.time.increaseTo(submissionDeadline + 1n);

      await aiJudge.write.revealAnswer([bountyId, ANSWER, SALT], {
        account: participant1.account,
      });

      const b = await aiJudge.read.getBounty([bountyId]);
      assert.equal(b[10], 1n); // submissionCount

      const [submitter, answer] = await aiJudge.read.getSubmission([bountyId, 0n]);
      assert.equal(getAddress(submitter), getAddress(participant1.account.address));
      assert.equal(answer, ANSWER);
    });

    await it("C2: reverts if reveal happens BEFORE submission deadline", async function () {
      const { aiJudge, participant1, bountyId } =
        await networkHelpers.loadFixture(committedFixture);

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, ANSWER, SALT], {
          account: participant1.account,
        }),
        "AIJudge: reveal phase not started yet"
      );
    });

    await it("C3: reverts if answer does not match commitment", async function () {
      const { aiJudge, participant1, submissionDeadline, bountyId } =
        await networkHelpers.loadFixture(committedFixture);

      await networkHelpers.time.increaseTo(submissionDeadline + 1n);

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, "WRONG ANSWER", SALT], {
          account: participant1.account,
        }),
        "AIJudge: commitment hash does not match"
      );
    });

    await it("C4: reverts if salt does not match commitment", async function () {
      const { aiJudge, participant1, submissionDeadline, bountyId } =
        await networkHelpers.loadFixture(committedFixture);

      await networkHelpers.time.increaseTo(submissionDeadline + 1n);
      const wrongSalt = keccak256(encodePacked(["string"], ["wrong-salt"]));

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, ANSWER, wrongSalt], {
          account: participant1.account,
        }),
        "AIJudge: commitment hash does not match"
      );
    });

    await it("C5: reverts on double reveal", async function () {
      const { aiJudge, participant1, submissionDeadline, bountyId } =
        await networkHelpers.loadFixture(committedFixture);

      await networkHelpers.time.increaseTo(submissionDeadline + 1n);
      await aiJudge.write.revealAnswer([bountyId, ANSWER, SALT], {
        account: participant1.account,
      });

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, ANSWER, SALT], {
          account: participant1.account,
        }),
        "AIJudge: already revealed"
      );
    });

    await it("C6: reverts if reveal phase has ended", async function () {
      const { aiJudge, participant1, revealDeadline, bountyId } =
        await networkHelpers.loadFixture(committedFixture);

      await networkHelpers.time.increaseTo(revealDeadline + 1n);

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, ANSWER, SALT], {
          account: participant1.account,
        }),
        "AIJudge: reveal phase has ended"
      );
    });

    await it("C7: reverts if caller never committed", async function () {
      const { aiJudge, participant2, submissionDeadline, bountyId } =
        await networkHelpers.loadFixture(committedFixture);

      await networkHelpers.time.increaseTo(submissionDeadline + 1n);

      await viem.assertions.revertWith(
        aiJudge.write.revealAnswer([bountyId, ANSWER, SALT], {
          account: participant2.account,
        }),
        "AIJudge: no commitment found for caller"
      );
    });
  });

  // ── D. judgeAll() guard conditions ─────────────────────────────────────
  await describe("D. judgeAll() guard conditions", async function () {
    await it("D1: reverts if reveal phase has not ended", async function () {
      const { aiJudge, owner, submissionDeadline, revealDeadline, reward } =
        await networkHelpers.loadFixture(deployFixture);

      await aiJudge.write.createBounty(
        ["Bounty", "Rubric", submissionDeadline, revealDeadline],
        { value: reward, account: owner.account }
      );

      await viem.assertions.revertWith(
        aiJudge.write.judgeAll([0n, "0x"], { account: owner.account }),
        "AIJudge: reveal phase not ended yet"
      );
    });

    await it("D2: reverts if called by non-owner", async function () {
      const {
        aiJudge,
        owner,
        participant1,
        submissionDeadline,
        revealDeadline,
        reward,
      } = await networkHelpers.loadFixture(deployFixture);

      await aiJudge.write.createBounty(
        ["Bounty", "Rubric", submissionDeadline, revealDeadline],
        { value: reward, account: owner.account }
      );

      await networkHelpers.time.increaseTo(revealDeadline + 1n);

      await viem.assertions.revertWith(
        aiJudge.write.judgeAll([0n, "0x"], { account: participant1.account }),
        "AIJudge: not bounty owner"
      );
    });
  });

  // ── E. finalizeWinner() guard conditions ───────────────────────────────
  await describe("E. finalizeWinner() guard conditions", async function () {
    await it("E1: reverts if bounty not yet judged", async function () {
      const { aiJudge, owner, submissionDeadline, revealDeadline, reward } =
        await networkHelpers.loadFixture(deployFixture);

      await aiJudge.write.createBounty(
        ["Bounty", "Rubric", submissionDeadline, revealDeadline],
        { value: reward, account: owner.account }
      );

      await viem.assertions.revertWith(
        aiJudge.write.finalizeWinner([0n, 0n], { account: owner.account }),
        "AIJudge: bounty not judged yet"
      );
    });
  });

  // ── F. computeCommitment() helper ──────────────────────────────────────
  await describe("F. computeCommitment() view helper", async function () {
    await it("F1: on-chain and off-chain commitment match", async function () {
      const { aiJudge, participant1 } =
        await networkHelpers.loadFixture(deployFixture);

      const answer = "Ritual enables AI inside smart contracts.";
      const salt = keccak256(encodePacked(["string"], ["some-salt"]));
      const bountyId = 0n;

      const onChain = await aiJudge.read.computeCommitment([
        answer,
        salt,
        participant1.account.address,
        bountyId,
      ]);
      const offChain = computeCommitment(
        answer,
        salt,
        participant1.account.address,
        bountyId
      );

      assert.equal(onChain, offChain);
    });
  });
});