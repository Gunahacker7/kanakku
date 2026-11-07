# Goldfish Review — Comprehension + Internal Consistency + Implementation Readiness

**Reviewer lens:** zero-context Goldfish (EGM Phase 3). Judged only from the documents.
**Documents read:** `concepts_brief.md`, `design_draft.md`, `KANAKKU-SPEC.md`, `docs/egm-workflow.md`.
**Design documents and app code were NOT modified by this review.**

---

## 1. Comprehension check

The design, restated from the draft alone:

1. v1.1 adds recurring transactions, budget alerts, and biometric unlock to a Flutter app whose state is encrypted JSON documents in a native store — no database, and no new pub or Gradle dependencies anywhere.
2. A recurring rule spawns dated occurrences: an `auto` rule posts a manual-store entry immediately; a `matchOrPost` rule waits a grace window for a captured bank transaction to claim the occurrence, and posts its own entry only if no capture arrives.
3. A capture that arrives after the fallback entry posted deletes that entry if the user never edited it, or flags it for one-tap user resolution if edited; deterministic entry ids make the whole engine pass idempotent and crash-safe.
4. Budget alerts are computed in Dart whenever fresh totals load: fire once per threshold (80%, then 100%) per category per budget month, re-arm only when a cap increase drops the percentage back below a fired threshold, aggregated into at most one notification per evaluation and two per day.
5. Biometric unlock is a framework `BiometricPrompt` verifier sitting beside the mandatory PIN — it never replaces the PIN, is enabled/disabled only through counted PIN verification, and every error path falls back to the PIN pad (fail-closed).
6. All new data is integer paise with legacy double-rupee values converted at a single boundary (`money.dart`); migration only adds two empty documents; backups gain the rules document but deliberately exclude alert state.

### UNDERSPECIFIED — parts that cannot be restated clearly from the draft

- **§3.3 step 1:** the match window is written `[date − 3d, date + graceDays]`. It cannot be determined whether the early bound is the constant 3 days or is meant to be `graceDays` (which is user-configurable, §3.1). The two readings give different matching behaviour.
- **§3.3 step 4:** "window widened to the capture's own date ±3d around the due date" is self-contradictory phrasing — the sweep's actual date test cannot be restated. It is also unclear in what sense ±3d "widens" a step-1 window whose late side is `graceDays` (which may exceed 3).
- **§3.4:** "they count in Home, Insights, budgets, exports, splits exclusion — splits unaffected" cannot be restated: do generated entries participate in splits, are they excluded, or is the splits feature merely untouched?
- **§4.4:** the Home banner shows for "any unfired-in-app crossing" — the term *unfired-in-app* is never defined anywhere, so the banner's trigger condition cannot be restated.

---

## 2. Consistency pass (brief ↔ draft ↔ spec, and draft ↔ draft)

**C1 — Match amount source contradicts itself (money correctness).**
§3.3 step 1 tests `paiseFromRupees(capture.amount) == rule.amountPaise`, but §3.5 mandates that matching use the amount **snapshotted onto the occurrence at creation**. Worse, the occurrence schema in §2.1 (date, state, entryId, captureKey, resolvedAt) contains **no `amountPaise` field at all** — §3.5 introduces it retroactively ("add field"). A developer following §2.1 + §3.3 builds behaviour that T-R12 (§7) explicitly tests against.

**C2 — Occurrence pruning (last 24, §2.1) breaks two other sections.**
(a) §3.3 step 4 sweeps `posted` occurrences up to **35 days** old, but a daily rule retains only 24 occurrences ≈ 24 days — older posted occurrences are pruned before the sweep can ever match them, so the double-count the sweep exists to heal survives silently. (b) §3.2's `maxCount` stop condition needs a count of fired occurrences; if counted from the (pruned) occurrence list, any `maxCount > 24` never triggers. The draft never says the count is computed from schedule math instead. (c) A pruned `flagged` occurrence takes its "Possible duplicate" resolution row with it while both entries remain in the ledger.

**C3 — §4.1 requires state that §2.3's schema does not contain.**
The re-arm rule depends on detecting that "cap value changed since last evaluation — track last-seen cap in state as `capPaise`", but the `alert_state_store` schema in §2.3 stores only `{"80": ts, "100": ts}` per category. As specified, the re-arm logic is unbuildable. Related minor dead weight: `_meta.lastNotifiedAt` (§2.3) is never used by any rule in §4.3, and the counting semantics of `_meta.notifiedDates` (one string per day? per notification?) are undefined even though the 2-per-day cap depends on them.

**C4 — Feature C fallback: brief and draft give different answers.**
The brief's recommendation is "C1 **with C2 fallback**" — device credential "kept as the fallback layer inside C1" for API < 28 / no enrolled biometrics. Draft §5.2 instead makes `unsupportedApi` devices see the toggle as **unavailable** and defers device-credential unlock to v1.2. The draft's change is marked [Guna-pending] in §5.2, but the brief's approver question list (§"Open questions", Q1–Q7) never surfaces this scope cut, so the human may approve believing C2 ships in v1.1.

**C5 — Pass ordering contradicts the catch-up bound (and T-R4).**
§3.3 lists step 3 (create occurrences for all due dates ≤ today; `auto` posts immediately) **before** step 5 (due dates older than today − 90 days are recorded `skipped` without posting). Read literally, a rule created with a startDate a year in the past posts a year of entries in step 3 before the 90-day bound is ever consulted — the opposite of what §7 T-R4 expects. The intended precedence (bound filters creation) is nowhere stated.

**C6 — Matching terminology drift.**
The brief (A3) promises "counterparty fuzzy-match"; the draft (§3.3 step 1) implements case-insensitive substring `contains`. The draft's version is the buildable one, but the brief overpromises matching quality to the approver. Also note the draft's skip rule — counterparty test "skipped if the capture has no counterparty" — appears only in the draft, silently widening matches to amount+direction+last4 alone.

**C7 — Unacknowledged divergence from the product spec.**
KANAKKU-SPEC §2.6 specifies budgets "per category **AND subcategory**" and a 50/30/20 salary split. The design scopes budgets to the existing per-category caps plus a new overall cap, and §9's out-of-scope list never mentions subcategory budgets or the split. Building on the existing store reality is defensible, but the divergence from product intent should be acknowledged in the draft so nobody implements (or approves) against the spec's wider reading.

---

## 3. Implementation readiness — where a developer would have to guess

**R1 — Empty `matchText` matches everything.** Matching is `counterparty.contains(matchText)`; an empty matchText is contained in every string. The draft never specifies validation or fallback (to label? to "cannot match"?) when the user clears the match text or the label is blank. Wrong-capture matches are a money-correctness risk.

**R2 — "Overall spent" is never composed.** §4.1 and T-B8 rely on an overall spent figure, but its composition is undefined: uncategorised transactions? Credits/income? Savings-bucket transfers (which are debits in the ledger but not consumption)? Each choice changes when the overall alert fires.

**R3 — Restore behaviour for the new key is explicitly unresolved.** §6 states the rule as "absent key in backup = leave current store untouched" but prefaces it with "verify against `parseBackup` behaviour and specify", and T-B3's expected result is "per §6 spec" — the test points at a spec that points back at the code. This must be settled in the document, not during implementation.

**R4 — `maxCount` counting semantics.** §3.2 says "count of fired occurrences" without defining *fired*: do occurrences `skipped` during a pause, or `skipped` by the 90-day bound, consume the count? A paused rule with `maxCount = 3` could auto-end having posted nothing — or not; the draft doesn't say.

**R5 — Late-match sweep ignores the one-capture rule.** Step 1 states a capture may satisfy only one occurrence across all rules; step 4's sweep never restates the constraint. A capture already recorded as rule X's `captureKey` could, on a literal reading, also sweep away rule Y's posted entry.

**R6 — No terminal state after duplicate resolution.** §3.3 step 4 defines "Keep both / Remove generated" choices but not the occurrence state afterwards. If it stays `flagged`, does the sweep re-flag it every pass and the row persist forever?

**R7 — Rule-id counter has no home.** §2.1 defines ids as `'rec_' + base36 ms + '_' + per-doc counter`, but the `recurring_store` schema (`{"rules": [...]}`) contains no counter field, and no other storage is named. (Deriving it from `rules.length` reintroduces id reuse after deletions, which can collide with a deleted rule's deterministic entry ids.)

**R8 — Category rename/delete orphans alert state.** Caps and alert state are keyed by category **name** (`budgets_store`, `cat:<name>` in §2.3). Renaming or deleting a category orphans its fired flags; a later category reusing the name inherits them and silently never alerts. The draft addresses neither rename nor cap deletion (a deleted cap also leaves the re-arm comparison in §4.1 without a defined behaviour).

**R9 — Unbounded/zero `graceDays`.** §3.1 exposes grace days as an advanced field with default 3 but no min/max. `graceDays = 0` interacts with step ordering (an occurrence created in step 3 can only expire in step 2 of a *later* pass — unstated), and a very large value keeps occurrences `pending` across month boundaries indefinitely.

**R10 — Paused and ended rules in the engine.** §3.3's pass runs "per active rule", while step 5 says pause-skips are recorded "when the rule is next processed" — when exactly a paused rule gets processed (on resume only?) is unstated, as is the fate of a `pending` occurrence whose rule's `endDate` passes before it resolves.

**R11 — Small undefined behaviours.** (a) Home-banner dismissal state has no field in §2.3. (b) Whether the native notification is suppressed when the app is in the foreground during evaluation. (c) Whether the recurring/alert passes run before or after the app-lock gate on cold start. (d) Whether a rule's `note` propagates to generated entries (§2.2 doesn't list it). (e) A user-deleted generated entry leaves its occurrence `posted` with a dangling `entryId` — sweep behaviour unstated. (f) Whether generated credits from a credit rule net against a capped category's spent in §4.1.

---

## 4. Verdict: **GO-WITH-FIXES**

The draft is structurally complete — data schemas, channel surface, migration, file map, and a genuinely attackable test checklist are all present, and the hard constraints (no new dependencies, paise, fail-closed lock, migration safety) are honoured throughout. No finding requires redesign; all fixes are localised spec edits. But findings 1–4 below are direct internal contradictions on money paths and must be resolved **before** code, not during it.

### Top 5 findings, ranked by severity

1. **§3.3 step 1 vs §3.5, and §2.1 schema (C1) — match-amount contradiction.** Matching reads the rule's live `amountPaise` in §3.3 but the occurrence snapshot in §3.5, and the §2.1 occurrence schema lacks the snapshot field entirely.
   *Fix:* add `amountPaise` to the §2.1 occurrence schema and make §3.3 steps 1 and 4 reference the occurrence snapshot only.
2. **§2.1 pruning vs §3.3 step 4 / §3.2 (C2) — last-24 pruning silently defeats the 35-day late-match sweep and any `maxCount > 24`.**
   *Fix:* prune by age *and* count (e.g. keep at least the last 40 days), never prune `pending`/`flagged` occurrences, and state that `maxCount` is counted from schedule math, not the pruned list.
3. **§4.1 vs §2.3 (C3) — the re-arm mechanism needs a `capPaise` field the alert-state schema doesn't define.**
   *Fix:* add per-category (and `__overall__`) `capPaise` to the §2.3 schema, and define `notifiedDates` counting (or replace it with a per-date count).
4. **§3.3 step order vs step 5 / T-R4 (C5) — literal pass order back-posts unlimited history before the 90-day skip bound applies.**
   *Fix:* state that the 90-day bound is applied inside step 3 before any occurrence is created or posted.
5. **Brief §C recommendation vs draft §5.2 (C4) — the device-credential fallback the brief recommends is silently cut from v1.1.**
   *Fix:* add an explicit approver question ("device-credential unlock for API < 28: v1.1 or v1.2?") to the brief's open-questions list so Guna decides it knowingly.

**Also fix before or during implementation (not verdict-blocking):** R1 (empty matchText), R2 (overall-spent composition), R3 (settle the §6 restore rule in the document), R4 (define "fired" for maxCount), R5 (extend the one-capture constraint to the sweep), R8 (category rename/delete vs alert state).
