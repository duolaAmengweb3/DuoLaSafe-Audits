# Silo Finance V3 (silo-core) Smart Contract Security Audit Report

**Auditor:** DuoLaSafe · Web3 Security Audit / On-chain Forensics
**Audit Date:** 2026-06-25
**Report Version:** v1.0
**Code Version (commit):** `silo-finance/silo-contracts-v3` @ `607535c`
**Contact:** Telegram [@dsa885](https://t.me/dsa885) · X [@hunterweb303](https://x.com/hunterweb303)

---

## Disclaimer & Confidentiality Notice

**This security audit report may contain sensitive information.** It documents potential vulnerabilities, attack paths, and exploitation analysis. We recommend deciding whether to publish only after issues are remediated.

DuoLaSafe has analyzed the target smart contracts according to industry best practices. **This audit is not a guarantee of absolute contract security**, nor does it constitute investment advice. All investors and users must perform their own due diligence. The audit scope is limited to the code and commit listed under "Audit Scope"; out-of-scope code (`silo-vaults`, `x-silo`, `silo-oracles`, `incentives`, deployment scripts), off-chain components, key management, frontend, and future upgrades are not covered by this assurance.

**Honest Disclosure:** Prior to this audit, Silo V3 had already undergone **multiple top-tier audits + Certora formal verification + enterprise-grade continuous auditing** (reports under `audits/v3/`) and maintains a `KnownIssues.md`. For a target like this, the probability of discovering new high/critical vulnerabilities is inherently very low. This report is positioned as **an independent, reproducible, adversarially-verified re-review of the silo-core core scope**, not a full re-audit.

---

## 1. Project Overview

### 1.1 Audit Scope

| Item | Description |
|---|---|
| Project Name | Silo Finance V3 (silo-core) |
| Language | Solidity 0.8.28 (core libraries); dependency range ^0.8.x |
| Deployment Chains | Multi-chain EVM (requires Cancun / transient storage) |
| Code Version | `silo-finance/silo-contracts-v3` @ commit `607535c` |
| Lines of Code | Core audit surface ≈ 3,300+ nSLOC (Silo 827 / SiloConfig 474 / Actions 638 / SiloLendingLib 494 / SiloMathLib 370 / SiloERC4626Lib 301 / SiloSolvencyLib 239, etc.) |
| Audit Period | 2026-06 |

**In-scope contracts:**

| Module | File | Responsibility |
|---|---|---|
| Core entry/config/dispatch | `Silo.sol` | ERC4626 lending vault main contract, action entry |
| | `SiloConfig.sol` | Cross-silo config coordination + transient cross-reentrancy lock |
| | `lib/Actions.sol` | Dispatch for deposit/withdraw/borrow/repay/liquidation |
| | `hooks/_common/TransientReentrancy.sol`, `utils/CrossReentrancyGuard.sol` | Cross-contract reentrancy protection |
| | `utils/ShareToken*.sol` | Collateral/debt share tokens |
| Lending math/shares/rounding | `lib/SiloLendingLib.sol` | Borrow/repay & interest accrual core |
| | `lib/SiloMathLib.sol` | share/asset/LTV conversions |
| | `lib/SiloERC4626Lib.sol`, `lib/Rounding.sol`, `lib/SiloStdLib.sol` | ERC4626 adapter, rounding direction, std utils |
| Solvency/liquidation | `lib/SiloSolvencyLib.sol` | Solvency check / LTV computation |
| | `hooks/liquidation/PartialLiquidation.sol` | Standard partial liquidation |
| | `hooks/defaulting/*`, `PartialLiquidationLib/ExecLib.sol` | Defaulting (bad-debt) liquidation & exec library |
| Interest-rate model/leverage/hook | `interestRateModel/InterestRateModelV2.sol`, `interestRateModel/kink/DynamicKinkModel.sol` | Interest-rate models (classic + dynamic kink) |
| | `leverage/LeverageUsingSiloFlashloan.sol`, `hooks/SiloHookV3.sol` | Flashloan leverage, hook wrapper |

**Out of scope (not audited this round):** `silo-vaults`, `x-silo`, `silo-oracles`, `incentives`, deployment scripts; and automated static analysis / formal verification (already covered by the project's Certora + prior audits).

### 1.2 Audit Introduction

This audit focuses on the **security-critical core of silo-core**: core entry & config, lending math & share conversion, solvency & liquidation, interest-rate models & leverage. Beyond per-function common-issue checks, we emphasized verifying that **cross-contract business flows are internally consistent** — deposit entry, borrow, repay, liquidation (both standard and bad-debt paths), interest accrual timing, share↔asset rounding direction, and state consistency / reentrancy boundaries under cross-silo coordination.

Every candidate finding underwent **adversarial verification**: either confirmed via attack model / PoC reasoning, or disproven by reading the actual code with the exclusion reason recorded publicly. We also de-duplicated against the repository's `KnownIssues.md` to ensure every item listed is a **new observation not separately covered by prior audits or known issues**.

### 1.3 Project Background

Silo V3 is an **isolated-market lending protocol**: each Silo is a pair of mutually isolated lending markets (two assets), with `SiloConfig` coordinating the collateral/debt relationship between the pair; core logic lives in libraries under `silo-core/contracts/lib/`. Unlike shared-pool lending (e.g., the Aave main pool), isolated markets confine each asset pair's risk to its own market, so a single asset's bad debt does not spill into other markets. Consequently, cross-silo state coordination and reentrancy boundaries are its distinctive risk surface.

**Fund flow & roles:**
- **Lender:** deposits assets into a silo for collateral shares (ERC4626 shares), earning borrow interest.
- **Borrower:** deposits collateral in one silo, borrows the other asset from the paired silo, must keep LTV below the liquidation threshold.
- **Liquidator:** when a borrower's LTV is exceeded, performs partial liquidation, repaying debt and seizing collateral shares at a discount.
- **Protocol/DAO:** collects protocol fees via `daoAndDeployerRevenue` and acts as the first backstop on bad debt.
- **Owner / Factory:** deploys and validates IRM / Kink config, hook receivers, etc. via the factory (trusted).

---

## 2. Audit Summary

### 2.1 Vulnerability Statistics

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 2 |

### 2.2 Audit Conclusion

**No vulnerabilities directly leading to fund loss were found (0 Critical / 0 High / 0 Medium).** The core invariant (total collateral value ≥ total debt value) is tightly protected:

- **Reentrancy lock coverage is complete** — write paths uniformly follow `turnOnReentrancyProtection → mutate state → check → turnOff`; share-token `transfer` acquires the same lock, and the `mint/burn` after-hook permits only read-only reentrancy within the lock.
- **Interest accrual timing is correct**, and share↔asset rounding is **conservative across the board** (no directional reversal, no precision loss from divide-before-multiply).
- **LTV computation has no directional bias**, and liquidation offers no "seize more collateral / repay less debt" arbitrage path.
- **ERC4626 inflation/first-deposit attacks** are correctly defended by decimal offset (=3 virtual shares) + `+1` virtual asset; economically infeasible.

**Most noteworthy residual risks (none reaching vulnerability severity):**
1. **Bad-debt (defaulting) accounting degeneracy (I-01, Low):** extreme bad debt can zero out `totalAssets[Collateral]` while leaving shares behind; the residual "ghost shares" dilute the next depositor; offset=3 only partially mitigates.
2. **Liquidation repay executes outside the reentrancy lock (I-02, Low):** standard liquidation transfers collateral shares first, then repays, with the global cross-reentrancy lock already off during repay; only a theoretical reentrancy surface if callback-capable assets (ERC777 / abnormal fee-on-transfer) are listed — a design trade-off plus asset constraint.
3. **DynamicKink interest handling inconsistent with V2 (I-03, Info):** under extreme config, `X_MAX` takes a `require` revert instead of graceful capping, discarding an entire interest segment.
4. **Bad-debt backstop lacks observability (I-04, Info):** no event distinguishes who bears the loss when bad debt is socialized.

---

## 3. Technical & Business Analysis

### 3.1 Technical Quick Assessment

| Main Category | Sub-item | Result |
|---|---|---|
| Contract programming | Solidity version | Pass (core pinned to `0.8.28`, Cancun + transient storage, built-in overflow checks) |
| | Integer overflow/underflow | Pass (0.8 checked arithmetic; `applyFractions` verified no underflow; interest overflow has a skip-accrual circuit breaker) |
| | Function input validation | Pass (action entries dispatched via `Actions` with config/amount checks; init constrained by `lt+fee<=100%`, `liquidationTargetLtv<=lt`) |
| | Access control management | Pass (IRM/Kink config set by factory-validated, trusted owner; leverage `onlyRouter` + per-user `Clones` clone) |
| | Reentrancy / race conditions | Pass (cross-silo transient reentrancy lock coverage complete; see I-02 as a defense-in-depth observation on out-of-lock repay, not a vulnerability) |
| | External call return-value checks | Pass (`trySub` return value discarded at I-04, affects observability only, not correctness) |
| | Price oracle manipulation | Pass / partially N.A. (`silo-oracles` out of scope this round; same-silo path skips `callSolvencyOracleBeforeQuote`, flagged as a phase-2 check) |
| Code conventions | Explicit function visibility | Pass |
| | Unused code | Pass (no security-relevant dead code found) |
| Gas optimization | Out-of-gas risk | Pass (IRM overflow/exception skips accrual without locking the silo; DynamicKink worst-case calldata gas quantification flagged for phase-2) |
| | High-consumption loops | Pass (no uncapped user-controlled loops on core paths) |

> Note: This round is manual core-scope review + adversarial verification; automated static analysis (Slither) and formal verification are covered by the project's Certora and prior audits, and were not re-run in full this round.

### 3.2 Business Risk Analysis (Token / Project Safety)

> **N.A. (not a token issuance):** Silo V3 is a lending **protocol**, not a single-ERC20 token issuance. The metrics below (buy/sell tax, mintability, blacklist, honeypot) target token-issuance projects and do not directly apply here. They are addressed item-by-item from a protocol perspective for completeness.

| Category | Result |
|---|---|
| Buy/sell tax | N.A. (no transfer tax; protocol fee accrues from interest via `daoAndDeployerRevenue`, not a trading tax) |
| Mintable | N.A. (no project token mint; ERC4626 collateral/debt shares are minted/burned per deposit/borrow actions, constrained by `SiloMathLib`) |
| Blacklist | None (no address blacklist at protocol layer; specific hook receivers may introduce one — trusted config) |
| Honeypot risk | None (lenders can `withdraw` normally subject to solvency and liquidity, not a one-way trap) |
| Anti-whale / anti-bot mechanisms | N.A. (no such mechanism in a lending protocol; risk governed by LTV/liquidation threshold) |
| Hidden owner | Trusted owner / factory (IRM/Kink config, hook receivers set by deployer via factory validation — trusted roles by design) |
| Control takeover possible | Upgrade/config authority rests with trusted owner / factory; hook receivers configured by deployer and trusted (key assumption) |
| Holder concentration | N.A. (not a token issuance) |
| Liquidity locked | N.A. (lending protocol liquidity is each silo's deposits, dynamic per borrow/lend, not an LP-lock concept) |

---

## 4. Code Quality & Security

### 4.1 Code Quality

The structure is clear with well-defined module boundaries: top-level `Silo.sol` (ERC4626 vault) + `SiloConfig.sol` (cross-silo coordination & transient reentrancy) serve as entries, with core business logic pushed down into pure-function libraries under `contracts/lib/` (`Actions` dispatch, `SiloLendingLib` borrow/repay & accrual, `SiloMathLib` math conversion, `SiloSolvencyLib` solvency, `SiloERC4626Lib` adapter); liquidation and interest-rate models are pluggable as hooks / standalone models. Rounding direction is centralized in `Rounding.sol` and is **conservative across the board** — a hallmark of high-quality lending code. The isolated-market model confines each asset pair's risk to its own silo, reducing systemic contagion.

### 4.2 Documentation

Comments reflect developer intent well; notably, **some known accounting-degeneracy properties are proactively disclosed in interface comments** (e.g., `IPartialLiquidationByDefaulting` self-states "can reset total assets completely while leaving shares behind … next deposit will lose the value of that left shares", corresponding to I-01). The repository maintains a `KnownIssues.md` explicitly registering known limitations, which is audit-friendly. Improvement: the bad-debt socialization path lacks events (I-04); observability for off-chain monitoring and accounting audits could be improved.

### 4.3 External Dependencies

Silo V3's core lending math **uses its own libraries** (`SiloMathLib` / `SiloLendingLib` / `Rounding` / `SiloSolvencyLib`, etc.) and **does not depend on third-party lending/math implementations such as Euler or OpenZeppelin**, so it is not indirectly affected by those external libraries' known issues. OZ-style infrastructure (e.g., `Clones`) is used only at the edges (e.g., leverage) for minimal-proxy cloning, with standard usage. Underlying assets are assumed non-malicious (comments state fee-on-transfer / rebasing / callback assets are unsupported). Transient storage relies on Cancun and is auto-cleared at end of transaction.

---

## 5. Audit Findings

### 5.1 Severity Definitions

| Level | Description |
|---|---|
| Critical | May directly lead to asset theft, vault drainage, or system-level loss of control |
| High | Major impact on business execution, user asset settlement, or permission boundaries |
| Medium | Important issue to fix promptly; may not immediately steal funds but breaks business correctness |
| Low | Style, compatibility, boundary, or minor-risk issues |
| Informational | Best-practice recommendations, no security impact |

> This audit found **no Critical / High / Medium vulnerabilities**. The following are 2 Low + 2 Informational observations.

### 5.2 Detailed Findings

#### [I-01] Defaulting liquidation can zero out `totalAssets[Collateral]` while leaving shares, creating "ghost shares" that dilute subsequent depositors  —  `Low`

- **Location:** `hooks/defaulting/PartialLiquidationByDefaulting.sol`, `hooks/defaulting/DefaultingSiloLogic.sol` (`_deductDefaultedDebtFromCollateral`)
- **Description:** In the defaulting (bad-debt) liquidation path, `_deductDefaultedDebtFromCollateral` deducts the cancelled debt from `totalAssets[Collateral]`. Under extreme bad debt, `totalAssets[Collateral]` can be driven to 0 while the corresponding collateral share `totalSupply()` remains > 0. The `IPartialLiquidationByDefaulting` interface comment self-acknowledges this: "can reset total assets completely while leaving shares behind … all shares worth 0 and next deposit will lose the value of that left shares".
- **Impact:** After the silo is fully wiped by bad debt, residual shares are worth zero. The **next depositor**'s `convertToShares` is diluted by the residual `totalSupply` — the mirror image of the ERC4626 first-deposit inflation attack (here arising from accounting degeneracy rather than an active attacker). The decimal offset (collateral offset=3) provides partial mitigation but does not fully eliminate it. Initialization is constrained by `lt+fee<=100%` and `liquidationTargetLtv<=lt`, so this is **not an attacker-arbitragable path**.
- **Reproduction / PoC (approach, flagged for phase-2):**
```text
1. Construct a single-asset defaulting market where all collateral is consumed by bad debt;
2. Trigger _deductDefaultedDebtFromCollateral so totalAssets[Collateral]=0 while share totalSupply>0;
3. Have a new depositor deposit and observe the dilution of convertToShares from the residual totalSupply;
4. Quantify the mitigation from offset=3 (compare dilution ratio with/without offset).
```
- **Remediation:** When `totalAssets[Collateral]` is zeroed out, handle (burn/reset) the residual shares as well, or enforce a minimum-liquidity floor per silo, avoiding the "0 assets + non-zero shares" accounting-degeneracy state.
- **References:** SC-Top10 SC02 (arithmetic/accounting precision); CWE-682 (Incorrect Calculation) / CWE-840 (Business Logic Errors).
- **Status:** Partially disclosed in interface comments but not separately listed in `KnownIssues.md`; added as a low-severity observation. **Unresolved**.

---

#### [I-02] In standard liquidation, collateral shares are transferred first and `repay` executes after reentrancy protection is turned off  —  `Low`

- **Location:** `hooks/liquidation/PartialLiquidation.sol:96-116`
- **Description:** `liquidationCall` executes in the order: ① `forwardTransferFromNoChecks` transfers away the borrower's collateral shares → ② `turnOffReentrancyProtection()` (L114) → ③ `ISilo(debtConfig.silo).repay(...)`. That is, **collateral is deducted first, debt repaid afterward**, and during repay the global cross-reentrancy lock is already off (`repay` itself re-acquires a lock).
- **Impact:** With normal ERC20 assets there is **no harm** (`repayDebtAssets` is already locked; the liquidator cannot underpay). Only if `debtConfig.token` is a **callback-capable asset (ERC777 / abnormal fee-on-transfer)** does the internal transfer callback inside `repay` create a theoretical cross-silo reentrancy surface. The protocol comments declare malicious assets are unsupported, so this is a design trade-off under a controlled premise.
- **Reproduction / PoC:** N.A. — depends on listing a callback-capable asset (explicitly unsupported by the protocol); no real exploit can be constructed on the compliant asset set.
- **Remediation:** Defense-in-depth — explicitly forbid ERC777 / callback-type assets at the silo-listing layer, hardening the implicit "no malicious assets" assumption into a code-level constraint.
- **References:** SC-Top10 SC05 (Reentrancy); CWE-841 (Improper Enforcement of Behavioral Workflow) / CWE-663 (Use of a Non-reentrant Function in a Reentrant Context).
- **Status:** Design trade-off + asset constraint; low severity. **Unresolved (recommended as defense-in-depth hardening)**.

---

#### [I-03] DynamicKinkModel `X_MAX` reverts via `require` instead of capping under extreme config, discarding an entire interest segment  —  `Informational`

- **Location:** `interestRateModel/kink/DynamicKinkModel.sol:370` (with the try/catch at `:451-465`)
- **Description:** After computing `_l.x`, `compoundInterestRate` **first** does `require(_l.x <= X_MAX)` (`X_MAX = 11e18`), and **only afterward** caps rcomp via `rcompCapPerSecond * T`. If `x` falls in `[x_at_cap, 11]`, the function reverts directly; the caller `_getCompoundInterestRate`'s catch returns `rcomp=0`, so the Silo only updates the timestamp and **the interest for the entire period becomes zero**. By contrast, `InterestRateModelV2` caps gracefully (returns `RCOMP_MAX`); the two handle this risk **inconsistently**.
- **Impact:** Unreachable under normal config (calculation: even with `kmax` at its legal upper bound, utilization maxed, and 5 years without accrual, `x` is only ~0.16, far below 11). Triggered only if the owner sets `kmax` to a near-unreasonable extreme like `UNIVERSAL_LIMIT` and interest goes un-settled for decades, in which case lenders lose the capped accrued interest. This is the concrete materialization, on the new model, of the IRM interest-skip family in `KnownIssues.md`.
- **Reproduction / PoC:** N.A. (requires owner-misconfig to an extreme value + decades without accrual; unreachable under normal factory validation).
- **Remediation:** Change to "**cap first, then check X_MAX**", or return the capped rcomp instead of reverting when `x > X_MAX`, consistent with V2's behavior.
- **References:** SC-Top10 SC09 (DoS / logic inconsistency); CWE-754 (Improper Check for Unusual or Exceptional Conditions) / CWE-691 (Insufficient Control Flow Management).
- **Status:** **Unresolved** (informational; align with V2 recommended).

---

#### [I-04] Defaulting bad-debt backstop silently absorbs the shortfall, with no event distinguishing who bears it  —  `Informational`

- **Location:** `hooks/defaulting/DefaultingSiloLogic.sol:50-56`
- **Description:** On genuine bad debt, the debt exceeding collateral is first deducted from `daoAndDeployerRevenue` via `trySub`; if the protocol fee is also insufficient, `trySub` returns `(false, 0)` and the remaining bad debt is **silently socialized** (borne by all lenders via reduced `totalAssets`). The `success` boolean is discarded, and **no event distinguishes** "protocol fee fully covered" from "lender-borne socialization".
- **Impact:** The bad-debt handling logic itself is **correct** (protocol fee covers first, then socialization), but lacks observability, affecting off-chain monitoring, risk alerting, and accounting audits.
- **Reproduction / PoC:** N.A. (logic correct; only an observability gap, no exploitable surface).
- **Remediation:** Emit an event on bad-debt socialization, recording the covered amount, the socialized amount, and distinguishing who bears the loss.
- **References:** SC-Top10 SC10 (Insufficient observability/monitoring); CWE-778 (Insufficient Logging).
- **Status:** **Unresolved** (informational).

---

## Adversarial Verification & Exclusions (Our Core Method) ★

> We perform reverse verification on every candidate finding — **either confirmed by PoC or disproven by reading the real code**. Below are the candidates excluded/downgraded this round, recorded publicly for transparency (this is what distinguishes us from "rubber-stamp audits").

| Candidate | Initial Take | Verification Conclusion |
|---|---|---|
| **`borrow` skips the liquidity check when `_token==0`, enabling debt from thin air** | High? | **❌ False report.** `SiloLendingLib.borrow`'s sole caller `Actions.borrow` (L174) always passes `debtConfig.token` (a real ERC20, non-zero); `_token=0` only appears in `transitionCollateral` (internal bookkeeping with no token movement). The external borrow liquidity check is always in effect. |
| **ERC4626 first-deposit / inflation attack** | High? | **❌ Defended.** `SiloMathLib._commonConvertTo` uses offset=3 virtual shares + `+1` virtual asset; an empty pool forces `totalAssets=0`. An attack requires donating ~1000× the victim's deposit — economically infeasible. |
| **share↔asset rounding can be farmed** | Med? | **❌ Conservative across the board.** Item-by-item check of `Rounding.sol`: deposits collect more asset / give fewer shares, borrows give less asset / record more debt, LTV rounds up — directionally favorable to the protocol, with no reversal or divide-before-multiply precision loss. |
| **Cross-silo reentrancy bypass** | High? | **❌ Coverage complete.** Write paths uniformly follow `turnOnReentrancyProtection → mutate state → check → turnOff`; share-token `transfer` acquires the same lock, and the `mint/burn` after-hook permits only read-only reentrancy within the lock. The before-hook executing outside the lock is a design boundary of the trusted hook receiver. |
| **Leverage `onFlashLoan` ignores `_initiator`** | Med? | **❌ Safe.** Per-user `Clones` clone + `onlyRouter`; a malicious flashloanTarget/swap can only harm the user themselves, with residual funds always returning to that user — nothing to farm (same conclusion as our Twyne audit F-9). |
| **Interest fractions underflow / interest overflow locking the silo** | Med? | **❌ Safe.** `applyFractions`'s integralInterest/Revenue are each ≤1 with early returns guaranteeing total≥1, so no underflow; interest overflow skips accrual without reverting (does not lock the silo) — a circuit breaker. |
| Same-asset liquidation 2-wei overestimation / share-dust liquidation | — | **Overlaps with `KnownIssues.md`, not counted as a finding** (dust liquidation already fixed with try/catch in 4.x). |

---

## Phase-2 (Deep Audit) Recommendations

1. **I-01 PoC:** Construct a single-asset defaulting market, zero out collateral `totalAssets` while leaving shares, and quantify the dilution of subsequent depositors and the degree of mitigation from offset=3.
2. **DynamicKink gas ceiling:** For the "more expensive IRM squeezed into interest-skip by OOG" called out in `KnownIssues.md`, quantify worst-case calldata gas on the new model (exp + multiple branches + external config reads).
3. **Oracle beforeQuote timing:** The same-silo path (`collateralConfig.silo == debtConfig.silo`) does not call `callSolvencyOracleBeforeQuote`; confirm whether any oracle depends on beforeQuote to refresh price → same-silo scenarios may use stale prices.
4. **Scope expansion:** Audit `silo-vaults`, `x-silo`, `silo-oracles`, `incentives`, and each concrete HookReceiver implementation separately.

---

## Audit Methodology

DuoLaSafe uses a collaborative tool + manual + dynamic-verification method:

1. **Manual line-by-line audit (4 parallel modules):** core entry/config, lending math/shares, solvency/liquidation, IRM/leverage/hook — four parallel tracks read the Solidity source, focusing on state coupling, lifecycle management, settlement baselines, and cross-contract authorization assumptions.
2. **Business-logic modeling:** build attack models from reserve manipulation, liquidation arbitrage, fee splitting, bad-debt socialization, and side-effect propagation.
3. **Adversarial verification:** reverse-verify each candidate — either confirm via PoC / attack model or disprove by reading the real code, recording the exclusion reason publicly (see "Adversarial Verification & Exclusions").
4. **Known-issue de-duplication:** read `KnownIssues.md` and the prior audits under `audits/v3/` to ensure all reported items are new observations not separately covered.
5. **Report output:** keep only verified issues, compress false positives, and bind each finding to a code path, impact, and remediation.

---

## Appendix: Tools & Versions

- **Audit method:** manual line-by-line + 4 parallel sub-audit modules + adversarial verification.
- **Testing/PoC:** Foundry (forge; PoC approaches in each finding's "Reproduction" section, I-01 flagged for phase-2 hands-on).
- **Automated/formal:** Full Slither / formal verification not re-run this round (already covered by the project's **Certora** formal verification + prior audits).
- **Known issues read:** `KnownIssues.md` (decimals offset not reflected in `decimals()`, incentives <3.6.0 `getProgramName`, IRM gas interest-skip, same-asset liquidation 2-wei overestimation & dust, SiloDeployer salt, etc.) — all de-duplicated.
- **Prior audits:** `audits/v3/` includes 0xJCN, an independent Security Review (2026-02), Certora (Dual Oracle formal verification), Cantina, enterprise-grade continuous auditing, etc.
- **Key assumptions:** underlying assets are non-malicious (comments declare fee-on-transfer / rebasing / callback assets unsupported); hook receivers configured by the deployer and trusted; IRM/Kink config set by a trusted owner via factory validation; transient storage (Cancun) auto-clears at end of transaction.
- **Contact:** Telegram [@dsa885](https://t.me/dsa885) · X [@hunterweb303](https://x.com/hunterweb303)

*© 2026 DuoLaSafe. This report applies only to the specified commit (`607535c`) and the assumptions above; the audit is not a guarantee of absolute contract security, nor investment advice. Re-audit is required after any modification.*
