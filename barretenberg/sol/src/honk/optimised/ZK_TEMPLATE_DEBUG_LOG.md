# ZK Optimized Template Debugging Log

## Current Status
- `forge test --match-contract BlakeOptZKTest` fails with `ShpleminiFailed` (pairing check returns false)
- Reference test `BlakeHonZKTest` (using `BaseZKHonkVerifier`) passes
- Template: `zk-honk-optimized.sol.template`
- Instance: `BlakeOptZK.sol` (generated via `sync_blake_opt_vk.sh --zk`)

## Fixed Issues
1. **LIBRA_UNIVARIATES_LENGTH was 17, should be 9** - This is `BATCHED_RELATION_PARTIAL_LENGTH`, NOT `(SUBGROUP_SIZE-1)/LOG_N`. Value 9 from `bn254.hpp:59`. Fixed. Also added `calldatacopy` zeroing of challengePolyLagrange scratch space since only 136/256 entries are set.
2. **Duplicate constant declarations** - EC_X_1..EC_Q_SIGN and LIBRA_UNIVARIATES_LENGTH had stale duplicates from the non-ZK template. Fixed.

## Areas to Investigate

### 1. Proof Field Loading Order
The ZK proof has extra fields vs non-ZK. The calldatacopy in the template must load them in the exact order the proof generator outputs them (matching the `ZKProof` struct in `HonkTypes.sol`).

**Reference proof struct order** (from `HonkTypes.sol`):
```
ZKProof {
    circuitSize, publicInputsSize, publicInputsOffset,
    pairingPointLimbs[8],
    geminiMaskingPoly (G1),       // <-- ZK extra
    w1, w2, w3, w4 (G1s),
    zPerm (G1),
    lookupReadCounts, lookupReadTags, lookupInverses (G1s),
    libraCommitments[0] (G1),     // <-- ZK extra (libra concatenation)
    libraSum (Fr),                // <-- ZK extra
    sumcheckUnivariates (9 * LOG_N Fr), // 9 per round for ZK
    geminiMaskingEvaluation (Fr),  // <-- ZK extra (entity[0])
    sumcheckEvaluations (41 Fr),   // entities[1..41]
    libraEvaluation (Fr),          // <-- ZK extra
    libraCommitments[1] (G1),     // <-- ZK extra (grand product)
    libraCommitments[2] (G1),     // <-- ZK extra (quotient)
    geminiFoldComms (LOG_N-1 G1s),
    geminiAEvaluations (LOG_N Fr),
    libraPolyEvals[4] (Fr),       // <-- ZK extra
    shplonkQ (G1),
    kzgQuotient (G1)
}
```
**Check**: Does the calldatacopy in the template load fields in this exact order to the correct memory locations? Cross-reference with the PROOF_* offsets in generate_offsets.py.

### 2. Eta Challenge Hash Input
**Reference** (`ZKTranscript.sol:generateEtaChallenge`):
- Hash input = prevChallenge(32) + publicInputs + pairingPointLimbs(256) + **geminiMaskingPoly(64)** + w1(64) + w2(64) + w3(64)
- Total: `0x220 + publicInputsSize` (was `0x1e0 + publicInputsSize` for non-ZK)

**Check**: Template `eta_input_length` calculation. Should be `add(0x220, public_inputs_size)` or equivalent. Look at the `ETA GENERATION` section (~line 1144-1190).

### 3. Libra Challenge Generation
**Reference** (`ZKTranscript.sol:generateLibraChallenge`):
- Hash input = prevChallenge(32) + libraConcat.x(32) + libraConcat.y(32) + libraSum(32) = 0x80 bytes
- Split into two 127-bit challenges: libraChallenge + unused

**Check**: This is a NEW challenge that doesn't exist in non-ZK. Must be inserted between gate challenges and sumcheck U challenges. Verify it exists and hashes the correct data.

### 4. Sumcheck Univariates Per Round
**Reference**: 9 Fr elements per round (ZK_BATCHED_RELATION_PARTIAL_LENGTH = 9)
- Hash input per round: prevChallenge(32) + 9 univariates(288) = 0x140 bytes

**Check**: Template sumcheck loop stride should be `0x120` (9 * 0x20 = 0x120 for univariates alone) or `0x140` including prev challenge. Was `0x100` (8 * 0x20) in non-ZK.

### 5. Rho Challenge Hash Input
**Reference** (`ZKTranscript.sol:generateRhoChallenge`):
- Hash input = prevChallenge(32) + **42 evals**(1344) + **libraEvaluation**(32) + **libraCommitments[1]**(64) + **libraCommitments[2]**(64)
- Total: 0x600 bytes (was 0x540 for non-ZK with 41 evals)

**Check**: Template rho hash section. Must include all 42 entity evals (geminiMaskingEval at index 0) + libraEvaluation + 2 libra commitments.

### 6. ShplonkNu Challenge Hash Input
**Reference**: prevChallenge(32) + geminiAEvals(LOG_N * 32) + **4 libraPolyEvals**(128)
- Total: 0x280 bytes (was 0x200 for non-ZK)

**Check**: Template nu hash section must include libra poly evals after gemini A evals.

### 7. Sumcheck Initial Target
**Reference**: `roundTarget = libraChallenge * libraSum` (non-ZK has `roundTarget = 0`)

**Check**: Template sumcheck initialization.

### 8. Sumcheck Final Check
**Reference**:
```
evaluation = product(u_challenges[2..LOG_N-1])  // partial product
adjustedTarget = accumulator * (1 - evaluation) + libraEvaluation * libraChallenge
```
Not just `eq(accumulator, roundTarget)` like non-ZK.

**Check**: Template sumcheck final check section.

### 9. Batch Scalar Ordering (Shplemini)
**Reference** (`CommitmentScheme.sol`):
- NUMBER_OF_ENTITIES = 42 for ZK (geminiMaskingEval is entity[0])
- NUMBER_UNSHIFTED = 37 (was 36)
- SHIFTED_COMMITMENTS_START = 30 (was 29)
- Entity eval order: geminiMaskingEval, then QM, QC, QL, QR, ... (same 41 as non-ZK)

**Check**: BATCH_SCALAR assignments. First unshifted entity should be GEMINI_MASKING_EVAL_LOC at BATCH_SCALAR_1_LOC. Indices 2-29 for VK polys. Indices 30-34 for shifted witness polys.

### 10. MSM Point Ordering
**Reference** (`BaseZKHonkVerifier.sol:computeBatchedCommitment`):
```
[0]  = shplonkQ
[1]  = geminiMaskingPoly          // ZK extra
[2-29] = VK commitments (28 polys)
[30-37] = witness commitments (8 polys)
[38-51] = gemini fold commitments (LOG_N-1 = 14)
[52-54] = libra commitments (3)   // ZK extra
[55] = generator [1,2] for constant term
[56] = KZG quotient
```
Total: 57 points (was 53 for non-ZK)

**Check**: Template MSM entries. Verify all G1_LOCATION/SCALAR_LOCATION stores match this ordering.

### 11. Libra Polynomial Batching in Shplemini
**Reference**: After gemini fold batching, process 4 libra poly evals with specific denominators:
- denominator[0] = 1/(shplonkZ - geminiR)
- denominator[1] = 1/(shplonkZ - SUBGROUP_GENERATOR * geminiR)
- denominator[2] = denominator[0]
- denominator[3] = denominator[0]

Then skip 2 powers of shplonkNu before the loop (interleaving artifact from C++).

**Check**: The `shplonkNu` power advancement. Are we skipping the right number of powers?

### 12. Constant Term Accumulation
The `constantTermAccumulator` feeds into the generator point scalar in the MSM. For ZK, it includes contributions from:
- All entity evals (42)
- Gemini A evals (LOG_N)
- Libra poly evals (4)

**Check**: All `constantTermAcc` additions match the reference.

### 13. Memory Layout Overlaps
Scratch regions for `checkEvalsConsistency`:
- CHALLENGE_POLY_LAGRANGE_BASE = 0x6000 (256 * 0x20 = 0x2000 bytes -> 0x6000-0x7FFF)
- CONSISTENCY_DENOMINATORS_BASE = 0x8000 (256 * 0x20 -> 0x8000-0x9FFF)
- CONSISTENCY_PRODUCTS_BASE = 0xA000 (256 * 0x20 -> 0xA000-0xBFFF)

**Check**: Do these overlap with the MSM working memory, accumulator, or any data needed for the pairing check?

### 14. Barycentric Domain Size
ZK uses 9 denominators for barycentric evaluation (not 8). Constants:
- 9 barycentric denominators (P_SUB_0 through P_SUB_8)
- 9 * LOG_N = 135 inverse slots

**Check**: Template constant definitions and sumcheck barycentric loop.

### 15. Proof Size Validation
**Reference**: `calculateProofSize` returns `(82 + 12 * LOG_N) * 32` for ZK.
Non-ZK is `(61 + 10 * LOG_N) * 32`.

**Check**: Template proof length check.

## Debugging Approach
1. Start with **proof loading** (#1) - if this is wrong, everything downstream fails
2. Then **challenge generation** (#2-#6) - if any challenge is wrong, sumcheck/shplemini fails
3. Then **shplemini batching** (#9-#12) - directly causes the pairing failure
4. Use `forge test -vvvvv` with trace to see exact precompile inputs
5. Could add debug reverts at key points to extract intermediate values and compare with reference
