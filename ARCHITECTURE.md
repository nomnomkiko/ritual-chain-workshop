# Architecture Note: Commit-Reveal vs. Ritual-Native Encrypted Submissions

## A. Commit-Reveal (Implemented — Required Track)

**Mechanism:** participants submit a `keccak256` hash of `(answer, salt,
sender, bountyId)` during the commit phase. The plaintext answer is only
revealed — and only becomes valid — after the submission window closes.

**Where plaintext exists:** nowhere on-chain until the reveal call itself.
Off-chain, only the participant who wrote the answer knows it (and possibly
stores it locally) until they submit the reveal transaction.

**Pros**
- Works on *any* EVM chain — no special precompiles needed.
- Simple to audit: correctness rests entirely on one hash comparison.
- Gas-cheap; no TEE or off-chain infrastructure dependency.

**Cons**
- Answers become fully public the instant they're revealed — *before*
  AI judging happens. A participant watching the mempool/chain during the
  reveal window could, in principle, read someone's reveal transaction
  before it's mined and try to front-run (though they can't "improve and
  resubmit," since the commit phase is already closed by then).
- Two transactions per participant (commit + reveal) instead of one.
- The reveal *deadline* is a trust boundary — if a participant misses it,
  their answer is lost even though they already invested effort.

## B. Ritual-Native Encrypted Submissions (Advanced Track — Design)

**Mechanism:** participants encrypt their answer client-side using the
Ritual LLM executor's public key (the same TEE-based encryption pattern used
for confidential precompile inputs, as covered in the workshop). The
contract stores only the ciphertext (or a content-addressed reference plus
hash) on-chain.

**Where plaintext exists:** only ever inside the TEE during the `judgeAll()`
execution. The TEE decrypts each submission using its private key, batches
all of them into one LLM prompt, and the LLM produces a ranking — all inside
the enclave. Plaintext answers are never exposed to the public chain, to
other participants, or even to the bounty owner before judging.

**What's on-chain vs. off-chain:**
- **On-chain:** ciphertext blobs (or `revealedAnswersHash` + `revealedAnswersRef` after judging), bounty metadata, the AI's final ranking/winner, the reward transfer.
- **Off-chain:** the actual encryption keys (executor-held, inside the TEE), and optionally the full revealed-answer bundle published to IPFS/storage after judging, with only its hash committed on-chain (to keep gas costs down, per the homework's "Suggested Reveal Pattern").

**How the LLM receives all submissions together:** all ciphertexts (or their decrypted equivalents) are batched into a single `llmInput` payload sent to the LLM precompile in one `judgeAll()` call — exactly like the required track's batching rule, but the executor performs decryption as a step inside the TEE before constructing the prompt, rather than the contract handling plaintext directly.

**How the final reveal happens:** after judging, the system can publish the full set of revealed answers (e.g., to IPFS) and store only `revealedAnswersHash = keccak256(bundle)` on-chain. Anyone can fetch the bundle and verify its hash matches, giving auditability without paying to store large strings in contract storage.

**Pros**
- Plaintext never touches the public chain or mempool, even momentarily — stronger privacy than commit-reveal.
- One round-trip per participant instead of two.
- Uses Ritual's actual value proposition (private compute + on-chain AI) rather than working around the lack of privacy primitives.

**Cons**
- Depends on Ritual's specific TEE/encryption infrastructure — not portable to other EVM chains.
- More complex: requires off-chain encryption tooling for participants, and trust that the TEE's attestation is sound (you're trusting the enclave's integrity guarantees, not just a hash check).
- Harder to test end-to-end without the live executor; debugging encryption mismatches is less transparent than a simple `keccak256` comparison.

## Recommendation

Commit-reveal is the right default for a generic, chain-agnostic bounty
contract. The Ritual-native approach is worth adopting specifically when the
goal is to showcase what makes Ritual different — private, AI-evaluated data
that never needs a public reveal step at all (useful e.g. for ongoing or
recurring competitions where you don't want *any* answers ever becoming
public, even after judging).
