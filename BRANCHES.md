# Branch model, promotion, and the experimental gate

This governs all three code repos — **faBolus**, **PumpX2Kit**, **faBolusGarmin** — which move in
lockstep (§1.3). `faBolus-internal` is private and single-branch and is not covered here.

Written per §1.1–§1.4 and §13 of the v3 handoff. It is deliberately in the repo root beside
`CONTRIBUTING.md` / `ARCHITECTURE.md`, **not** in the mkdocs site: it is contributor governance, not
end-user documentation.

## The three branches

| Branch | What it is | CI | Who runs it |
|---|---|---|---|
| `deprecated` | A **frozen snapshot** of `main` as it stood on 2026-08-04, *before* the round-3 safety fixes. Tag `deprecated/2026-08-04-v0.1.0-build1`. **Not a supported fallback** — rolling back here reintroduces every known P0. No further commits. | — | nobody; forensics/bisection only |
| `main` | The current, CI-green, release-blocking-set baseline. Everything here has passed CI under the real toolchain. | push + PR + dispatch | self-compilers following the build docs |
| `experimental` | Work that meets the §1.2 classification below. Default-off, unproven, or unverifiable-against-the-pump features live here until promoted. | push + PR + dispatch | **the developer only**, until the clinical-review gate is satisfied (below) |

Two tags track goodness over time:

- `deprecated/2026-08-04-*` — immovable; the pre-fix snapshot.
- `safe-baseline/2026-08-04` — the **moving** last-known-good pointer, advanced as each release-blocking
  phase lands. This is the rollback target, not `deprecated`.

## §1.2 — what belongs on `experimental`

A feature belongs on `experimental` (not `main`) if it **fires on a threshold, automates a decision, or
produces output the user cannot immediately verify against the pump.**

By that rule, several features currently on `main` are misclassified and must move on the next
promotion pass. Recorded here as a **decision**, not left to be discovered at the first promotion:

| Feature | Why it is `experimental` | State today |
|---|---|---|
| Hypo / predicted-low banner | produces a glucose projection the user cannot verify against the pump | default-off; also under C3/§3.2 decision (P16) |
| Eating nudges | fires on a detector threshold | default-off, `#if FABOLUS_NUDGE` |
| Smart Assist bolus warnings | automates a judgement about a proposed dose | default-off, `#if FABOLUS_NUDGE` |
| Sleep / Exercise automation | automates a pump-mode decision on a schedule | default-off (Mobi-only) |

All four are default-off and three are already behind `#if FABOLUS_NUDGE`, so the move is small — but it
is a move, and it happens as part of creating/curating `experimental`, not silently.

## §1.4 — promotion criteria (written before the first promotion, deliberately)

`experimental` exists from this phase onward, so these criteria are set **now** — leaving them to a
later phase would leave every intervening promotion ungoverned. A feature promotes `experimental → main`
only when **all** hold:

1. **Verifiable or clearly bounded.** Either its output can be checked against the pump, or it is
   presented as advisory with that limitation stated in the UI at the point of use.
2. **Default-off preserved if it automates.** Anything that fires on a threshold or automates a decision
   ships default-off on `main` too, with a one-time plain-language explanation.
3. **CI-green on the real toolchain**, across every surface it touches (not just locally — CI runs a
   stricter Xcode than a typical dev machine; a local green is necessary, not sufficient).
4. **Tests pin the behaviour**, including the failure/edge path, not only the happy path.
5. **No new capability inferred where the pump already answers it** — read the pump, don't model it
   (C4). New inference is a promotion blocker until it is shown the pump can't supply the fact.
6. **Clinical review** (below) is complete for any feature touching dosing guidance, thresholds, or
   automation copy — this is a hard gate, not a checklist item.
7. **Disposition honoured.** Nothing that would move the delivery disposition off **NO-GO for real
   insulin delivery** promotes without that being the explicit, separate subject of the change.

## Clinical-review gate — a distribution constraint on `experimental` itself

§13 requires endocrinologist / CDCES review of **DS1, L6, H1–H4, K1–K2** and the **§2.1 therapy-editing
copy** *before anyone outside the developer runs an `experimental` build.*

This is a constraint on **distributing the branch**, so it lives with the branch:

- **Do not distribute `experimental` builds** (TestFlight, sideload to another person, store beta) until
  that review is complete and recorded.
- The developer building and running `experimental` on their own device for bench work is fine.
- When the review is done, record it here with date and reviewer, and only then widen distribution.

This plan/repo work **cannot** satisfy this gate — it needs a clinician. It is stated so the constraint
travels with the branch rather than being lost.

## Cross-repo CI is branch-aware (§1.2)

The three repos build against each other (faBolus consumes PumpX2Kit as a local package; faBolusGarmin
validates against faBolus's schema). CI checks out the sibling at the branch **matching** the branch
under test, falling back to `main` when no same-named counterpart exists — so an `experimental` faBolus
builds against `experimental` PumpX2Kit. The resolver logs the resolved ref **and its SHA**, because the
one dangerous failure is a silent fallback that greens a mismatch. See each repo's
`.github/workflows/ci.yml` (`resolve-refs` in faBolus; the inline `fbref` step in faBolusGarmin).

## Order of operations

Per §1.2: `deprecated` was cut first (before any merge, so it captures the pre-fix `main`), then the
round-3 fixes merged to `main`, then `experimental` was created from the fixed `main`. Creating
`experimental` from a pre-fix `main` would have carried the P0s into it.
