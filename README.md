# DisplayClassPlanner

**An unfold is a capacity event, not a layout event — and almost every guide stops at the layout half.**

When a foldable opens, when Split View widens, when Stage Manager resizes a window, when an external
display attaches: the advice is "adopt `NavigationSplitView` and adapt your layout." That advice is
correct and it is not the hard part.

The hard part is that the viewport roughly doubled *while requests were in flight*. A detail pane now
exists that is demanding content nobody asked for. Prefetch depth, decode budget and concurrency were
all sized for a surface that no longer exists. And the whole thing can reverse in 300 ms.

`DisplayClassPlanner` is the layer underneath the layout: it treats a display-class change as a
**re-planning event over in-flight work**, and it makes the two guarantees that are easy to state and
easy to get wrong.

---

## Why this matters

The naive implementation of "the screen got bigger, re-plan" is three lines long and contains two
production bugs.

```swift
// The version that ships, and the version that gets a Jira ticket six weeks later.
func displayClassChanged(to viewport: Viewport) {
    cancelAllPrefetches()                       // bug #1
    startPrefetches(for: itemsVisible(in: viewport))
}
```

**Bug #1 — the duplicated fetch.** Roughly 80% of what you just cancelled is in the list you are about
to start. On cellular, the user pays for those bytes twice; on screen, they see a flash of empty cells
in content that was already loaded. It does not reproduce on a desk, because a desk has Wi-Fi.

**Bug #2 — the storm.** Fold, unfold, fold. A drag that crosses a breakpoint and comes back. Each
crossing runs the cancel-and-restart cycle again. The surface never settles, and the network log looks
like a retry loop nobody wrote.

There is a third bug that only shows up in the crash-free sessions dashboard, which is to say it never
shows up: **a response that was in flight when you cancelled it still arrives.** If your handler drops
it because "that request was cancelled," and the item has since been re-admitted, you re-request bytes
that are already sitting in memory.

This package's answer to all three is the same idea: **plan by stable identity, and emit a diff.**

---

## The design

```
     Viewport (sanitised)
            │
            ▼
  TransitionDebouncer ──── asymmetric hysteresis ──── withdraws reverted storms
            │                                          (0 requests cancelled)
            ▼  committed viewport
      BudgetPolicy ──────── area → { depth, concurrency, decode bytes }
            │
            ▼  CapacityBudget
     PlanReconciler ─────── in-flight × desired → PlanTransition
            │                                    { retained, reprioritized,
            │                                      cancelled, admitted }
            ▼
    CapacityPlanner ────── generation fencing, in-flight table, completion verdicts
       (actor)
```

Five pieces, each independently testable, each replaceable:

| Type | Responsibility | Seam |
|---|---|---|
| `Viewport` | The package's single trust boundary. Normalises NaN, infinity, negatives and absurd values so nothing downstream has to. | — |
| `BudgetPolicy` | Measured surface → work budget. | Protocol. `AreaProportionalBudgetPolicy` is the default. |
| `TransitionDebouncer` | Asymmetric hysteresis. Pure value type, takes an explicit `now`. | `Policy` struct, or bypass with `.immediate`. |
| `PlanReconciler` | The diff. Pure, synchronous, deterministic. | `Policy` struct for the two admission trade-offs. |
| `CapacityPlanner` | The actor that owns generation, in-flight state and completion verdicts. | Composes all of the above via `init`. |

### Design decision 1 — the output is a diff, not a plan

`PlanTransition` has four buckets, and the names are the instructions:

- `retained` — already running, still wanted, same priority. **Do nothing.** Touching these is bug #1.
- `reprioritized` — already running, new priority. Re-order the queue; do not restart the request.
- `cancelled` — was running, no longer wanted.
- `admitted` — newly wanted, not currently running.

*Rejected alternative:* return the desired set and let the caller diff it. Simpler API, and it hands
every caller the same bug to write. The reconciliation is the value; exporting it as homework defeats
the point.

The invariant this buys is checkable, and it is exposed as `PlanTransition.validate(inFlight:)`:

> **Consistency** — no identity appears in `cancelled` and in any of `retained` / `reprioritized` /
> `admitted`, and none appears in two of them.
>
> **Completeness** — every identity that *was* in flight appears in exactly one bucket.

The second half is the one that matters more and is the easier one to forget. Contradiction-checking
alone cannot see an id that the transition simply fails to mention: that request is never cancelled
and never kept, so it runs forever and its slot is never reclaimed. `validate()` with no argument can
only check consistency; `validate(inFlight:)` checks both. Pass the set when you have it.

### Design decision 2 — hysteresis is asymmetric

Expansion and contraction are not the same event, so they do not get the same treatment.

- **Expanding applies immediately.** A pane appeared and it is empty. Delay is visible.
- **Contracting is held** (400 ms by default). The pane that is leaving still has its content; nothing
  looks wrong while we wait. Holding costs nothing.
- **A reversal during the hold withdraws the pending change entirely.** Fold-unfold-fold settles having
  cancelled *zero* requests.

Two details that are easy to get wrong and are tested explicitly:

- A repeated observation of the same pending class **keeps its original deadline**. Extending it on
  every observation is the classic debounce-starvation bug — a surface emitting size changes at display
  refresh rate during a drag would push the deadline out forever and never commit.
- `TransitionDebouncer.withdrawnCount` is exported deliberately. It is the metric that justifies the
  hysteresis existing: **if it stays at zero in production, the hold is pure latency and should be
  turned off.** A tuning knob with no counter behind it is superstition.

*Rejected alternative:* a symmetric debounce on both directions. Simpler, one constant instead of two,
and it makes every unfold feel 400 ms slow for no benefit.

### Design decision 3 — generation fencing, with salvage

Every commit bumps a monotonic generation and stamps admitted work with it. When a response lands, the
planner returns one of four verdicts:

| Verdict | Meaning |
|---|---|
| `.accepted` | Current generation. Ordinary. |
| `.acceptedStale` | Older generation, but still wanted. Keep it. |
| `.salvaged(originalGeneration:currentAdmission:)` | **Issued, cancelled, re-admitted, and only now arriving.** The payload satisfies the new admission. |
| `.discarded` | Cancelled and never re-admitted. Drop it. |

`.salvaged` is the case a hand-rolled implementation almost always gets wrong, because the obvious
guard is `if response.generation != currentGeneration { return }` — which throws away bytes you already
paid for, for an item you currently want.

**What the caller has to do to actually save the fetch.** Cancellation on iOS is cooperative:
`URLSessionTask.cancel()` is a request, and bytes already on the wire still arrive. So a caller that
treats `admitted` as "open a connection right now, unconditionally" has already spent those bytes by
the time this verdict can be returned, and `.salvaged` degrades into a diagnostic. To benefit, keep
your outstanding-response table keyed by `WorkID` and, when an id is admitted, check it before
issuing. The planner reports the situation; it cannot un-send a request you chose to send.

### Design decision 4 — the actor never suspends

`CapacityPlanner` is an actor and **every method on it is synchronous internally.** There is no `await`
anywhere in its body. That is load-bearing: an actor method that suspends can be interleaved with
another call to the same actor, so a `read → await → write` sequence would let a second fold event
observe a half-applied plan and diff against state that no longer exists.

All I/O — issuing requests, cancelling them — belongs to the caller, which receives a `PlanTransition`
*value* and does its awaiting outside. **The actor computes; the caller suspends.**

`snapshot()` returns one `PlannerSnapshot` value rather than exposing a dozen `async` properties, for
the same reason: six separate reads are six suspension points, and the values a caller assembles that
way need never have been true simultaneously.

### Design decision 5 — the oversized head item is admitted

If the first visible cell alone exceeds the whole decode budget, it is admitted anyway.

*The trade-off:* with the exemption off, a surface whose hero asset happens to be very large renders
permanently blank — the priority-ordered admission loop skips it every pass and nothing behind it fills
the hole either. With it on, the budget can be overshot by exactly one item. Overshooting a soft memory
budget by one asset is recoverable; a permanently blank hero cell is a bug report. Both behaviours ship
(`PlanReconciler.Policy.admitsOversizedHeadItem`) and both are tested.

---

## Crash-safety, on purpose

A planner derives its numbers from `CGSize` values that arrive from UIKit/SwiftUI mid-transition — and
those are exactly the values that come through as `0`, as `.nan`, or as something absurd during a
rotation or a fold. "It can't be NaN in practice" is not a safety argument; it is a prediction about a
value you do not own.

So every conversion and every arithmetic operation in this package that *could* trap goes through
`Saturating` — including the ones that are provably safe at their call site, because a rule with
remembered exceptions is not a rule:

- `Int(someDouble)` traps on NaN, on ±infinity, and out of range → `Saturating.int(clamping:)`, whose
  bounds are derived from `Int.max` / `Int.min` rather than 64-bit literals, so they stay correct
  wherever `Int` is not 64 bits wide.
- `+` and `*` overflow → `Saturating.adding` / `Saturating.multiplying`, clamping to the correct end.
- `/` by zero, and `Int.min / -1` → `Saturating.dividing`.
- Deadlines are `now + hold` on a `UInt64` clock → saturating, so a clock near its ceiling delays a
  commit instead of wrapping into the past.

`Saturating` deliberately has **no `%`**. This package never takes a remainder, and a saturating `%`
sitting there unused would be dead code in the one file whose whole job is to be trustworthy.

There are **no force-unwraps and no unchecked subscripts anywhere in the package.** Growth is bounded
structurally: the in-flight table only grows through admission, admission is capped by
`CapacityBudget.maxPrefetchDepth` (512), and the diagnostic event log is a ring of
`CapacityPlanner.maxEventLogSize` (64).

---

## Verification

`swift build -Xswiftc -warnings-as-errors` and `swift test -Xswiftc -warnings-as-errors` were run on a
clean tree (`.build` removed first) with Swift 6.0.3 on Linux:

```
Build complete!                       0 warnings
Executed 90 tests, with 0 failures
```

| Suite | Tests | What it holds down |
|---|---:|---|
| `SaturatingTests` | 13 | Every input that makes the built-in operator trap |
| `ViewportTests` | 8 | NaN / negative / absurd dimensions, classification boundaries |
| `BudgetPolicyTests` | 7 | Exact hand-computed budgets, hard ceilings, degenerate policy inputs |
| `PlanReconcilerTests` | 16 | Admission order, dedupe, budget edges, plus a 400-case property test |
| `TransitionDebouncerTests` | 13 | Storms, deadline non-extension, clock-ceiling saturation |
| `CapacityPlannerTests` | 14 | Generation fencing, salvage, bounded ring, 120 concurrent writers |
| `InvariantCheckerTests` | 19 | **Deliberately broken transitions, asserting the checker fails** |

Three things in there are worth naming, because they are the tests that would otherwise have been
comfortable and useless:

- **`InvariantCheckerTests` feeds `validate()` broken input on purpose.** A checker that returns `[]`
  for everything would make every other test in the suite pass while catching nothing. Each test hands
  it a transition that is wrong in one specific way and asserts the matching violation — with two
  positive controls, so a checker that reported violations *unconditionally* would fail too.
- **The 400-case property test passes the in-flight set.** Without it, `validate` can only find
  contradictions, and the property test would pass against a `reconcile` that returned an empty
  transition for every input. With it, that implementation fails on the first iteration.
- **The concurrency test asserts something the code does not satisfy by construction.** 120 real
  concurrent tasks write to the same actor, and the assertion is that the generations handed out are
  exactly `1...n` — no duplicates, no gaps. A duplicate means two commits diffed against the same
  pre-state; a gap means a generation was burned without producing a transition. A subset-or-count
  check would have caught neither.

CI runs the same two commands on every push. See the repo's **Actions** tab for live status.

---

## Using it

```swift
.package(url: "https://github.com/rajatslakhina/display-class-planner-kit.git", from: "1.0.0")
```

```swift
import DisplayClassPlanner

let planner = CapacityPlanner(
    viewport: .zero,
    budgetPolicy: AreaProportionalBudgetPolicy(averageCellArea: 14_400),
    debouncePolicy: .default
)

// On every size change:
switch await planner.apply(viewport: measured, desired: catalog, at: monotonicNanos) {
case .unchanged:
    break
case .held(let deadline):
    scheduleTick(at: deadline)                  // contraction is waiting out its hold
case .withdrawn(let replan):
    // The storm reverted. Nothing was cancelled.
    if let replan { apply(replan) }
case .replanned(let transition):
    apply(transition)
}

func apply(_ t: PlanTransition) {
    // `t.retained` is deliberately absent from this function.
    t.cancelled.forEach(cancel)
    t.reprioritized.forEach { requeue($0.id, at: $0.to) }
    for item in t.admitted where !hasOutstandingResponse(item.id) {
        // The guard is what makes `.salvaged` worth something: a response for
        // this id may still be on the wire from before it was cancelled.
        start(item, generation: t.generation)
    }
}

// When a response lands:
switch await planner.complete(id, generation: issuedGeneration) {
case .accepted, .acceptedStale, .salvaged:
    store(payload)                              // all three keep the bytes
case .discarded:
    break
}
```

`DisplayClassPlannerUI` ships a SwiftUI surface (`CapacityPlannerView`) that drives all of this live.
The whole module is behind `#if canImport(SwiftUI)`, so the package still builds and tests on Linux.

**Demo app:** *(added after the companion repo is pushed — see below)*

---

## Scope, honestly

This is the planning layer. It does not fetch, decode, cache or draw anything — it decides *what should
be in flight and at what priority*, and it tells you the minimal set of changes to get there. Wiring it
to `URLSession`, an image pipeline or a `SwiftData` prefetcher is deliberately left to the caller,
because those choices are where a real app's constraints live.

The display-class thresholds in `Viewport` are **this package's defaults, chosen so a single-column
phone-sized surface lands in `.compact` and a two-pane surface lands in `.regular`. They are not Apple
hardware specifications and are not claimed to be.** Supply your own classification to match your device
matrix.

## Requirements

Swift 6.0+ · iOS 17+ (the core module is platform-agnostic and is built and tested on Linux in CI)

## Licence

MIT — see [LICENSE](LICENSE).
