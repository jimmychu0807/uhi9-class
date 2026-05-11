---
name: Uniswap v4 tranche and fixed APY hooks
overview: "Design two Uniswap v4 hook-based products: a senior/junior tranche LP structure and a fixed APY liquidity subscription model backed by swap fees plus external yield."
todos:
  - id: define-product-semantics
    content: Finalize legal/economic semantics for 'guaranteed' senior return and fixed APY backstop hierarchy.
    status: pending
  - id: design-accounting
    content: Specify epoch checkpoint math, liability accrual, and claim token/share accounting structs.
    status: pending
  - id: split-hook-vs-manager
    content: Define which logic remains inside hook callbacks vs keeper/manager execution paths.
    status: pending
  - id: risk-and-oracles
    content: Define oracle sources, APY quoting guardrails, utilization caps, and circuit breakers.
    status: pending
  - id: test-harness
    content: Implement unit, invariant, and fork tests for insolvency, manipulation, and redemption edge cases.
    status: pending
isProject: false
---

# Uniswap v4 Hook Design Plan

## Goal

Provide implementable architecture for two hook products on Uniswap v4:

- YieldBasis-style senior/junior tranching over LP exposure
- Fixed APY subscription over time-locked liquidity

## Shared Foundation

- Start from Uniswap `v4-template` and implement hook contracts via `BaseHook` / OpenZeppelin hook primitives.
- Use one hook contract per strategy family, but keep state scoped by `PoolId` (`mapping(PoolId => StrategyState)`) so multiple pools are supported safely.
- Build around these callback points:
  - `beforeAddLiquidity`/`beforeRemoveLiquidity`: enforce product rules (lock windows, tranche accounting, share mint/burn)
  - `beforeSwap`/`afterSwap`: collect or route fee accounting snapshots used for tranche and APY accrual
- Keep product accounting in vault-share terms (ERC-4626-like shares internally) instead of raw token balances to handle partial exits and compounding cleanly.

## Feature 1: YieldBasis-Style Tranche Hook

### Product Model

- LP deposits into a hook-owned vault linked to one v4 pool/range policy.
- Mint two claims:
  - Senior tokens: target fixed return schedule (priority claim)
  - Junior tokens: residual claim (fees + IL + under/over-performance)
- Hook (or companion manager) controls actual pool liquidity and rebalancing policy.

### Core Mechanics

- Define accounting periods (epochs).
- At each epoch close:
  1. Compute vault NAV = pool position value + unclaimed fees.
  2. Accrue senior obligation = principal + fixed rate for elapsed period.
  3. Allocate PnL waterfall:
    - First to senior until obligation met
    - Remaining to junior
    - If shortfall, junior absorbs first; optionally carry senior deficit forward.
- Store per-epoch checkpoint structs so redemptions are deterministic and O(1)-ish per user (claim index + cumulative factors).

### Hook Responsibilities vs Manager Responsibilities

- Hook:
  - Gate deposits/withdrawals by epoch state
  - Track fee deltas from swaps/liquidity events
  - Enforce pool/fee/range constraints
- External manager (recommended):
  - Rebalance ranges
  - Trigger epoch rollover
  - Perform NAV valuation with robust oracle inputs

### Key Risks to Engineer

- Oracle manipulation: never use spot pool price for NAV; use TWAP + external oracle bands.
- Insolvency semantics: explicitly define what “guaranteed” means (contractual priority, not protocol guarantee).
- Queue/liquidity mismatch: exits should be epoch-based or subject to capacity constraints.

## Feature 2: Fixed APY Subscription Hook

### Product Model

- LP chooses lock term (e.g., 7/30/90 days), deposits principal, receives a fixed APY quote at entry.
- Yield sources:
  - Primary: swap fee income from associated v4 liquidity
  - Supplemental: external lender adapters (Aave/Morpho) for idle/hedge capital
- Hook enforces lock and mints a receipt position (ERC-721 or ERC-1155 style claim token is practical).

### Core Mechanics

- On subscribe:
  - Snapshot principal, term, APY, maturity timestamp.
  - Reserve required liability in “promised yield” accounting bucket.
- During term:
  - Periodically route realized fees + external adapter yield into reserve pool.
- At maturity:
  - Payout = principal + fixed yield.
  - Any excess yield to protocol/junior buffer.
- If reserve deficit emerges:
  - Use predefined backstop order (insurance buffer -> protocol treasury -> haircut policy).

### Adapter Layer (Aave/Morpho)

- Use separate adapter contracts with strict allowlists and caps.
- Keep adapter calls outside swap hot path where possible; hook should mostly read accounting flags, while keeper/manager handles reallocation.
- Add circuit breakers per adapter (pause, max utilization, max loss threshold).

### Key Risks to Engineer

- Duration mismatch: APY liabilities are fixed, fee income is variable; manage with conservative APY quoting curve and utilization caps.
- External protocol risk: isolate with per-adapter exposure limits and emergency unwind paths.
- Lock bypass and griefing: enforce term logic in hook + non-transferable receipt mode if needed.

## Testing and Validation Strategy

- Unit tests:
  - Waterfall allocation correctness across gain/flat/loss epochs
  - Maturity payout correctness under partial reserve funding
- Fuzz/invariant tests:
  - Conservation of value (assets = liabilities + equity buffer)
  - Senior priority invariant
  - No unauthorized early unlock
- Fork tests:
  - Realistic fee flows and adapter interactions on target chain
- Adversarial tests:
  - Oracle shock, swap volatility spikes, adapter pause/failure, bank-run redemption patterns

## Suggested Build Order

1. Build minimal tranche vault without external yield.
2. Add epoch waterfall and senior/junior claim tokens.
3. Add fixed APY subscriptions using same reserve engine.
4. Integrate one external adapter (Aave first), then Morpho.
5. Add risk engine (quoting caps, circuit breakers, backstops).

## Deliverables for Prototype

- `TrancheHook.sol` + `TrancheManager.sol`
- `FixedApyHook.sol` + `YieldReserve.sol` + `AaveAdapter.sol`/`MorphoAdapter.sol`
- Test suite with invariant + fork coverage
- Risk parameter config and ops runbook (epoch rollover, pause, emergency unwind)

