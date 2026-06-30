// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./utils/PrecompileConsumer.sol";

/**
 * @title AIJudgeCommitReveal
 * @notice Privacy-preserving AI Bounty Judge on Ritual Chain.
 *
 * ── LIFECYCLE ─────────────────────────────────────────────────────────────
 *
 *  1. BOUNTY CREATION  (t = 0)
 *     Owner calls createBounty() with title, rubric, submissionDeadline,
 *     revealDeadline, and msg.value as reward.
 *
 *  2. COMMIT PHASE  (t < submissionDeadline)
 *     Participants call submitCommitment() with a hash of their answer.
 *     Commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
 *     The plaintext answer is NOT stored on-chain → nobody can copy it.
 *
 *  3. REVEAL PHASE  (submissionDeadline <= t < revealDeadline)
 *     Participants call revealAnswer(bountyId, answer, salt).
 *     Contract re-computes the hash and verifies it matches the stored commitment.
 *     Only valid reveals become eligible for AI judging.
 *
 *  4. JUDGE PHASE  (t >= revealDeadline)
 *     Owner calls judgeAll(bountyId, llmInput).
 *     Contract batches ALL revealed answers into a single prompt and sends it
 *     to Ritual's LLM precompile.  The AI returns a review recommending a winner.
 *
 *  5. FINALIZE  (after judging)
 *     Owner calls finalizeWinner(bountyId, winnerIndex).
 *     Contract transfers the reward to the winner's address.
 *
 * ── PRIVACY PROPERTIES ────────────────────────────────────────────────────
 *  • During the commit phase: only commitment hashes are on-chain, so
 *    other participants CANNOT read the answers.
 *  • After reveal: answers become public, but the submission phase is already
 *    closed, so nobody can submit a new (improved) answer.
 *  • This is stronger than the workshop version where answers were public
 *    immediately, allowing copy-cat submissions.
 *
 * ── RITUAL INTEGRATION ────────────────────────────────────────────────────
 *  Uses Ritual's LLM precompile (0x0802) for batch judging.
 *  All revealed answers are sent together in ONE LLM call (not one per answer).
 *  The contract also uses IRitualWallet to fund precompile execution fees.
 */

// ---------------------------------------------------------------------------
// IRitualWallet – interface for the on-chain fee wallet required by Ritual
// ---------------------------------------------------------------------------
interface IRitualWallet {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

contract AIJudgeCommitReveal is PrecompileConsumer {
    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2000;

    // Ritual Wallet address (fixed on Ritual chain – do NOT change)
    IRitualWallet public constant RITUAL_WALLET =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // ── State ──────────────────────────────────────────────────────────────
    uint256 public nextBountyId;

    // ── Structs ────────────────────────────────────────────────────────────

    /**
     * @notice Stores the revealed answer of a participant.
     *         Created only after a successful revealAnswer() call.
     */
    struct Submission {
        address submitter;
        string  answer;
    }

    /**
     * @notice Full bounty state.
     *
     * Deadlines
     * ---------
     * submissionDeadline : participants can commit until this timestamp
     * revealDeadline     : participants must reveal before this timestamp
     *
     * Hidden-phase state
     * ------------------
     * commitments        : maps submitter → commitment hash (set at commit time)
     * hasCommitted       : prevents double-commitment per bounty
     * hasRevealed        : prevents double-reveal per bounty
     *
     * Post-reveal state
     * -----------------
     * submissions        : array of successfully revealed answers (eligible for AI)
     * judged / aiReview  : set after judgeAll()
     * finalized / winner : set after finalizeWinner()
     */
    struct Bounty {
        address owner;
        string  title;
        string  rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool    judged;
        bool    finalized;
        string  aiReview;
        uint256 winnerIndex;
        Submission[] submissions;
        mapping(address => bytes32) commitments;  // address → commitment hash
        mapping(address => bool)    hasCommitted;
        mapping(address => bool)    hasRevealed;
    }

    /**
     * @notice ConvoHistory required by Ritual's documentation for LLM context management.
     *         We do not resume context between calls, but the field is required.
     */
    struct ConvoHistory {
        string  storageType;
        string  storagePath;
        string  secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    // ── Events ─────────────────────────────────────────────────────────────
    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string  title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(
        uint256 indexed bountyId,
        string  aiReview
    );

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // ── Modifiers ──────────────────────────────────────────────────────────

    modifier onlyBountyOwner(uint256 bountyId) {
        require(
            msg.sender == bounties[bountyId].owner,
            "AIJudge: not bounty owner"
        );
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(
            bounties[bountyId].owner != address(0),
            "AIJudge: bounty does not exist"
        );
        _;
    }

    // ── 1. createBounty ────────────────────────────────────────────────────

    /**
     * @notice Create a new bounty.
     * @param title               Short title describing the bounty challenge.
     * @param rubric              Judging criteria sent to the AI during judgeAll().
     * @param submissionDeadline  Unix timestamp: participants can commit until here.
     * @param revealDeadline      Unix timestamp: participants must reveal before here.
     *                            Must be > submissionDeadline.
     * @return bountyId           ID of the newly created bounty.
     */
    function createBounty(
        string  calldata title,
        string  calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0,                              "AIJudge: reward must be > 0");
        require(submissionDeadline > block.timestamp,       "AIJudge: submission deadline must be in the future");
        require(revealDeadline > submissionDeadline,        "AIJudge: reveal deadline must be after submission deadline");

        bountyId = nextBountyId++;

        Bounty storage b = bounties[bountyId];
        b.owner              = msg.sender;
        b.title              = title;
        b.rubric             = rubric;
        b.reward             = msg.value;
        b.submissionDeadline = submissionDeadline;
        b.revealDeadline     = revealDeadline;
        b.winnerIndex        = type(uint256).max; // sentinel: not set yet

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    // ── 2. submitCommitment ────────────────────────────────────────────────

    /**
     * @notice Commit to an answer without revealing it.
     *
     *   commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *
     *   The caller should keep (answer, salt) secret until the reveal phase.
     *   Including msg.sender and bountyId in the hash prevents another participant
     *   from reusing the same commitment on a different bounty or impersonating them.
     *
     * @param bountyId   ID of the target bounty.
     * @param commitment Hash computed off-chain by the participant.
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp < b.submissionDeadline, "AIJudge: submission phase has ended");
        require(!b.hasCommitted[msg.sender],            "AIJudge: already committed for this bounty");
        require(b.submissions.length < MAX_SUBMISSIONS, "AIJudge: max submissions reached");

        b.commitments[msg.sender] = commitment;
        b.hasCommitted[msg.sender] = true;

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    // ── 3. revealAnswer ────────────────────────────────────────────────────

    /**
     * @notice Reveal the plaintext answer and salt during the reveal phase.
     *
     *   The contract verifies:
     *     keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)) == stored commitment
     *
     *   Only a matching reveal is recorded as an eligible submission.
     *
     * @param bountyId  ID of the bounty.
     * @param answer    Plaintext answer (must match what was committed).
     * @param salt      Random bytes chosen by the participant at commit time.
     */
    function revealAnswer(
        uint256          bountyId,
        string  calldata answer,
        bytes32          salt
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp >= b.submissionDeadline, "AIJudge: reveal phase not started yet");
        require(block.timestamp <  b.revealDeadline,     "AIJudge: reveal phase has ended");
        require(b.hasCommitted[msg.sender],              "AIJudge: no commitment found for caller");
        require(!b.hasRevealed[msg.sender],              "AIJudge: already revealed");
        require(bytes(answer).length > 0,                "AIJudge: answer cannot be empty");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "AIJudge: answer too long");

        // Verify the commitment hash
        bytes32 expectedCommitment = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(
            expectedCommitment == b.commitments[msg.sender],
            "AIJudge: commitment hash does not match"
        );

        b.hasRevealed[msg.sender] = true;

        uint256 submissionIndex = b.submissions.length;
        b.submissions.push(Submission({
            submitter: msg.sender,
            answer:    answer
        }));

        emit AnswerRevealed(bountyId, submissionIndex, msg.sender);
    }

    // ── 4. judgeAll ────────────────────────────────────────────────────────

    /**
     * @notice Ask Ritual's LLM to judge all revealed answers in a single batch call.
     *
     *   Can only be called after the reveal deadline, so all answers are public
     *   at this point (participants can no longer submit new commitments).
     *
     *   The llmInput bytes must be constructed off-chain according to Ritual's
     *   25-field AI reference format (see docs.ritual.foundation).
     *   The recommended system prompt should include the bounty rubric and all
     *   revealed answers, instructing the LLM to return the index of the best answer.
     *
     * @param bountyId  ID of the bounty.
     * @param llmInput  ABI-packed Ritual LLM input bytes (25-field format).
     */
    function judgeAll(
        uint256        bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyBountyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp >= b.revealDeadline, "AIJudge: reveal phase not ended yet");
        require(!b.judged,                           "AIJudge: bounty already judged");
        require(b.submissions.length > 0,            "AIJudge: no revealed submissions to judge");

        // ── Call Ritual's LLM precompile ──────────────────────────────────
        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        // ── Decode the response ───────────────────────────────────────────
        // Output layout (from Ritual docs):
        //   (bool hasError, bytes completionData, bytes /* unused */, string errorMessage, ConvoHistory /* unused */)
        (
            bool    hasError,
            bytes   memory completionData,
            /* bytes memory _unused */,
            string  memory errorMessage,
            /* ConvoHistory memory _convoHistory */
        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, string(abi.encodePacked("AIJudge: LLM error - ", errorMessage)));

        // completionData is the raw UTF-8 AI response text
        string memory aiReview = string(completionData);

        b.judged   = true;
        b.aiReview = aiReview;

        emit AllAnswersJudged(bountyId, aiReview);
    }

    // ── 5. finalizeWinner ──────────────────────────────────────────────────

    /**
     * @notice Finalize the winner and transfer the bounty reward.
     *
     *   The bounty owner reviews the AI's recommendation (stored in aiReview)
     *   and confirms (or overrides) the winner index.  This human-in-the-loop
     *   step guards against AI hallucinations.
     *
     * @param bountyId     ID of the bounty.
     * @param winnerIndex  Index into the submissions array of the chosen winner.
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyBountyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(b.judged,                                    "AIJudge: bounty not judged yet");
        require(!b.finalized,                                "AIJudge: bounty already finalized");
        require(winnerIndex < b.submissions.length,          "AIJudge: invalid winner index");

        Submission storage winner = b.submissions[winnerIndex];

        b.finalized   = true;
        b.winnerIndex = winnerIndex;

        // Transfer reward to winner
        (bool sent, ) = payable(winner.submitter).call{value: b.reward}("");
        require(sent, "AIJudge: reward transfer failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner.submitter, b.reward);
    }

    // ── View helpers ───────────────────────────────────────────────────────

    /**
     * @notice Get the main details of a bounty (excluding internal mappings).
     */
    function getBounty(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string  memory title,
            string  memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool    judged,
            bool    finalized,
            string  memory aiReview,
            uint256 winnerIndex,
            uint256 submissionCount
        )
    {
        Bounty storage b = bounties[bountyId];
        return (
            b.owner,
            b.title,
            b.rubric,
            b.reward,
            b.submissionDeadline,
            b.revealDeadline,
            b.judged,
            b.finalized,
            b.aiReview,
            b.winnerIndex,
            b.submissions.length
        );
    }

    /**
     * @notice Get a specific revealed submission (available only after reveal phase).
     */
    function getSubmission(uint256 bountyId, uint256 index)
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage b = bounties[bountyId];
        require(index < b.submissions.length, "AIJudge: invalid submission index");
        Submission storage s = b.submissions[index];
        return (s.submitter, s.answer);
    }

    /**
     * @notice Check whether an address has committed (but not necessarily revealed).
     */
    function hasCommitted(uint256 bountyId, address participant)
        external
        view
        bountyExists(bountyId)
        returns (bool)
    {
        return bounties[bountyId].hasCommitted[participant];
    }

    /**
     * @notice Check whether an address has successfully revealed.
     */
    function hasRevealed(uint256 bountyId, address participant)
        external
        view
        bountyExists(bountyId)
        returns (bool)
    {
        return bounties[bountyId].hasRevealed[participant];
    }

    /**
     * @notice Convenience function to compute the commitment hash off-chain.
     *         Call this (or replicate it in JS) to generate the commitment before
     *         calling submitCommitment().
     */
    function computeCommitment(
        string  calldata answer,
        bytes32          salt,
        address          participant,
        uint256          bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, participant, bountyId));
    }

    // ── Ritual Wallet helpers ──────────────────────────────────────────────

    /**
     * @notice Deposit funds into Ritual Wallet to pay for LLM precompile calls.
     *         The bounty owner should call this before calling judgeAll().
     */
    function depositToRitualWallet() external payable {
        RITUAL_WALLET.deposit{value: msg.value}();
    }

    /**
     * @notice Check the contract's balance in Ritual Wallet.
     */
    function getRitualWalletBalance() external view returns (uint256) {
        return RITUAL_WALLET.balanceOf(address(this));
    }

    // Allow contract to receive ETH (needed for reward storage)
    receive() external payable {}
}
