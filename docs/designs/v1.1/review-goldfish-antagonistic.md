# Goldfish Review — Antagonistic Lens (money math · security · data loss)

**Reviewer stance:** zero prior context; documents only.
**Documents judged:** `design_draft.md`, `concepts_brief.md` (v1.1 design),
`SECURITY-AUDIT-2026-10-29.md` (baseline), `KANAKKU-SPEC.md`.
**Verdict: GO-WITH-FIXES** — the skeleton is sound (additive migration §6,
fail-closed gate §5.4, deterministic posting ids §2.2), but four findings can
each produce wrong money or lost data in realistic flows, and one finding is an
undisclosed weakening of the v1.0.4 audit baseline. All fixes are spec-level;
no redesign is needed. None of the five may be deferred to "implementation
detail."

---

## Top 5 findings (ranked)

### 1. HIGH — Restoring a backup resurrects deleted/stale rules, which then mass-back-post against a ledger that already contains the real payments
**Refs:** draft §6 (backup adds `'recurring'` incl. occurrences), §3.3 step 5
(90-day catch-up posts everything missed), §3.3 step 6 / brief "Deterministic
entry ids" (idempotency claim).
**Attack:** User deletes a rent rule in December and pays rent manually (or it
is captured). In January they restore a November v1.1 backup (the file sitting
in WhatsApp — exactly the F15 restore flow). The rule returns with a stale
occurrence list. On next launch the engine catch-up-posts up to 90 days of
occurrences. Deterministic ids do **not** protect: the user's replacement
entries are human entries with different rawBodies, and captures older than
the rolling-500 SMS store cannot match. Result: up to 3 months of rent (and
every other rule) double-counted in one pass, silently. The same applies to
*any* restore of a backup older than the current ledger, not just deleted
rules.
**Fix:** On restore, imported rules start `paused` and all occurrences due
before the restore date are quarantined as `skipped` pending a one-tap user
review ("3 rules restored — resume?"); nothing back-posts from a restore
without explicit confirmation.

### 2. HIGH — The idempotency argument proves the engine never double-*posts*; the actual invariant is never double-*counting*, and the capture layer breaks it
**Refs:** draft §3.3 steps 1 & 6, §1 table (captures "deduped by
`ParsedTransaction.dedupeKey`"); brief §0.3; spec §2.3 (SMS + notification +
email must become ONE entry).
**Attack:** `dedupeKey = amount(2dp)|last4|upiRef` has no date and no
counterparty, and the UPI ref is formatted differently (or absent) across the
SMS and notification channels. The same real payment therefore routinely
survives `loadTransactions()` **twice** under two different dedupeKeys. The
engine consumes one twin as the occurrence match; the other twin remains a
live capture and counts in every total — spend counted twice, occurrence
marked `matched`, and no generated entry exists for the late-match sweep to
remove. The corruption is invisible and permanent. The fuzzy half is no
better: step 1's substring `contains` match on counterparty text plus
amount+last4 can consume a *different* real payment of the same amount inside
the window (two ₹499 subscriptions; an ad-hoc transfer to the same
counterparty), marking the occurrence matched while the true payment posts
later as a fallback entry — double count again, in the opposite shape.
"Consumed-keys + earliest-due-first" (§3.5) makes the assignment
*deterministic*, not *correct*; the draft repeatedly treats determinism as
soundness.
**Fix:** State the invariant as "totals count each real payment once" and
defend it at the capture layer: group captures by (paise, last4, date) before
matching, treat a second unmatched capture in the window as ambiguity →
occurrence `flagged` for one-tap resolution instead of silently matching, and
add a test with the same payment arriving via both SMS and notification with
different refs.

### 3. HIGH — Occurrence pruning (24) silently defeats `maxCount` and the 35-day late-match sweep
**Refs:** draft §2.1 ("pruned to last 24 per rule"), §3.2 (stop condition =
"count of fired occurrences ≥ maxCount"), §3.3 step 4 (sweep covers `posted`
occurrences "within the last 35 days"), test T-R15 (maxCount = 3 only).
**Attack:** The fired-count is derived from a list that is capped at 24. A
daily rule with `maxCount = 30` can never reach 30 in the retained list, so it
**never ends** and keeps posting real ledger entries past the user's cap —
money created by a bookkeeping bug. Symmetrically, a daily rule's occurrence
from 30 days ago has been pruned before the 35-day late-match sweep can see
it, so a late capture for it double-counts with no cleanup path. T-R15 passes
while the bug ships, because 3 < 24.
**Fix:** Persist a monotonic `firedCount` and `lastFiredDate` on the rule
itself (never derive counts from the pruned occurrence list), raise the prune
floor above the sweep window (e.g. keep ≥ 60 occurrences or all `posted` ones
younger than 40 days), and add a test with maxCount = 30 on a daily rule.

### 4. HIGH — Generated entries carry two amount representations, and the draft never states the invariant that keeps them in sync — downgrade safety depends on the answer
**Refs:** draft §2.2 (keys table; loader "prefers `amountPaise`"), brief
Cross-cutting ("generated entries carry **both** `amount` (double) and
`amountPaise`"), draft §6 + brief ("v1.0.4 ignores additive keys… corrupts
nothing"), §2.2 `editedByUser` row.
**Attack:** The brief promises both fields are written; the draft's §2.2 table
never lists the legacy `amount` key for generated entries, and no section
states who maintains it. Two failure branches: (a) if `amount` is absent,
v1.0.4's manual-store decoder reads a null amount on downgrade — generated
entries vanish or the old app faults — directly contradicting §6's "no
existing transaction is touched" and the brief's "corrupts nothing" claim
(test T-X2 would catch this only if it uses *generated* entries, which it
does not say). (b) If both are written, the existing edit path updates the
double `amount`; §2.2 only requires it to stamp `editedByUser`. Unless the
edit path also recomputes `amountPaise`, totals (which prefer paise) keep the
old figure while the transaction list shows the new one — the ledger and the
UI silently disagree about the same entry.
**Fix:** Add one normative sentence: generated entries MUST write
`amount = rupeesFromPaise(amountPaise)` in the same object write, every edit
of a generated entry MUST recompute `amountPaise` from the edited amount in
the same write, and T-X2 must restore into v1.0.4 with generated entries
present.

### 5. MEDIUM-HIGH — Biometric unlock is a parallel door around the v1.0.4 lockout and is enrollment-blind; the draft's "baseline not weakened" claim is false as written
**Refs:** draft §5.4 ("biometric success unlocks even while a PIN lockout
timer is running"), §5.5 ("v1.1 does not change that model"), brief §C
(enrollment-change blindness, marked [Guna: aware]); audit F1/F7 and threat
model (a) "a person holding the unlocked phone for a minute"; audit Sound #3 /
F7 note that the PIN encrypts nothing (F3 context).
**Attack:** v1.0.4's headline hardening (audit top fix #1) made PIN guessing
expensive: counted failures, 30 s→900 s lockouts. §5.4 gives biometrics an
unconditional pass around that lockout, and prompt-only auth (no auth-bound
Keystore key — §5.1/§5.5 admit this) cannot detect enrollment changes.
Concretely, against the audit's own adversary (a): a person with brief access
to the unlocked phone who knows or has observed the *device* credential
enrolls their own fingerprint once in Android Settings; from then on Kanakku
opens for them forever, the app cannot notice, the PIN counters never move,
and — per §5.4 — even an active lockout is irrelevant. §5.5's Settings copy
("keeps casual viewers out") is honest; the draft's repeated claim that the
v1.0.4 baseline is "not weakened" is not: the lock's strength is now
min(PIN-with-lockout, device-biometrics-with-enrollment-blindness), which is
strictly weaker for exactly the adversary the audit ranked first. What an
attacker with the unlocked phone gains from v1.1 that v1.0.4 never granted:
*persistent, silent, self-provisioned access* — they no longer need the phone
owner's finger or PIN, only one enrollment moment.
**Fix:** Correct the claim in §5.5 and in the approval questions (the brief's
Q4/Q6 disclose the pieces but never state the lockout-bypass consequence), and
make an active PIN lockout suspend biometric unlock until it expires or a
counted PIN verification succeeds — biometrics resume after; the auth-bound
Keystore key stays the documented long-term fix.

---

## Further findings (fix in the same pass)

**6. MEDIUM — §6 ships an unresolved either/or on the destructive restore
path.** "Absent key in backup = leave current store untouched (this must be
tested, §7 T-B3)" — the two branches have opposite data-loss profiles (wipe
the rules vs. keep rules whose ledger was rolled back). A destructive-path
behaviour cannot be a test-time discovery; specify it in §6 now, including
the crash-mid-restore case: restores write per-document commits (§2.5), so a
kill mid-restore leaves a mixed-generation store set that the engine will
happily reconcile on next launch. Add a restore-in-progress flag the engine
respects.

**7. MEDIUM — Phantom income from unmatched credit rules.** §3.3/§3.4: a
salary rule on `matchOrPost` that fails to match posts a generated *credit*.
Net pay varies month to month (arrears, deductions), so exact-paise matching
(§3.3 step 1) fails precisely for salary; the phantom credit then coexists
with the real salary capture when it lands in a form that doesn't match —
income double-counted, "left to spend" overstated. Overstated available money
is worse than an overstated expense. Fix: default credit rules to a "confirm
before posting" variant of `matchOrPost`, or match credits on
counterparty+window with amount tolerance and flag the difference.

**8. MEDIUM — The match window is defined three different ways.** Brief A3:
"within ±3 days of the due date." Draft §3.3 step 1: pending occurrences with
"due date within [date − 3d, date + graceDays]" (whose `date`? the capture's?
today's?). Draft §3.3 step 4: "window widened to the capture's own date ±3d
around the due date" — a phrase that does not parse into one interval. Three
implementers will build three engines; T-R6/T-R8 exercise only the happy
middle. Fix: one normative window definition, referenced by all steps.

**9. MEDIUM — Fuzzy late-match deletion can delete a legitimate entry.**
§3.3 step 4 auto-removes an untouched generated entry when a capture "now
matches." A second, genuinely distinct payment of the same amount to the same
counterparty inside the widened window (rent advance + regular rent; a repeat
transfer to the same person) triggers deletion of the real fallback entry —
the ledger now *under*counts, and unlike a duplicate, a missing entry is
invisible to the user. Deletion on a fuzzy match is more dangerous than
posting on one. Fix: auto-delete only on a strong match (equal paise AND
equal last4 AND upiRef present/equal or counterparty exact-normalised);
anything weaker goes to the same `flagged` one-tap flow used for edited
entries.

**10. MEDIUM — "Alerts" are app-open evaluations, and backdated entries
rewrite already-reported history; the wording still overpromises.** Brief
§0.6/B2 admits nothing evaluates while the app is closed, and draft §4.4 does
include a Settings note — good. But (a) the feature is still named and specced
as "alerts" (spec §2.6) while a user who overspends via UPI and never opens
Kanakku receives nothing until the open that would have shown them the
Budgets screen anyway; (b) §4.3 rule 2 silently swallows the day's 3rd
crossing — a 100% breach can produce no notification at all while the user
believes alerts are on; (c) recurring entries backdated to due-date noon
(§2.2) retroactively change past days' totals *after* the daily-summary alarm
has already posted those days' figures (§0.6: summaries are text computed
earlier) — history changes with no marker. Fix: carry the "checked when you
open the app" wording into the Budgets screen header and the first-alert
notification itself, surface suppressed crossings in the next day's in-app
banner count, and mark back-posted entries in Transactions with their posting
date on the detail view.

**11. LOW — Refund asymmetry is a totals issue, not just a missing feature.**
§3.4 documents that refunds are never auto-linked. Consequence not stated: a
`posted` occurrence whose real payment was refunded before any capture
arrives leaves a generated debit plus a captured refund credit with no debit
capture — net position wrong by the refund until the user intervenes. At
minimum the Recurring screen should surface unmatched credits whose
counterparty matches a rule's `matchText` as "possible refund."

**12. LOW — Rule-id uniqueness rests on creation-ms + a "per-doc counter"
whose derivation is unspecified (§2.1).** If the counter is derived from the
current rules list, delete-then-create within the same millisecond after a
restore can reissue an existing id, aliasing two rules' occurrences. Fix:
derive the counter from a persisted monotonic value in the document (or use
createdAt + a random suffix).

## What the design gets right (so the fixes stay surgical)
- Migration §6 is genuinely non-destructive: additive documents, no rewrite
  of `manual_store`, idempotent re-run, honest rollback story (subject to
  Finding 4's missing sentence).
- Gate work preserves the F13 lesson: every biometric/channel failure routes
  to the PIN pad, never to an unlocked app (§5.3, §5.4, T-C7).
- Notification content hygiene follows F12 (SECRET visibility, percentages
  only) and the anti-spam caps (§4.3) are concrete and testable.
- The brief's §0 ground-truth section (no database, doubles today, derived
  captures, zero plugins) is exactly the honesty the draft needs more of in
  §5.5 and §6.

## Bottom line
Fix Findings 1–5 in the spec text (each is a paragraph or less), resolve
Finding 6 by decision rather than by test, and this design is safe to build.
Building it as written ships: a restore flow that can triple-book a quarter's
rent, a matcher that can silently double-count the most common payment shape
in the app, a `maxCount` that does not count, and an app lock materially
weaker than the one v1.0.4's audit demanded — while claiming otherwise.
