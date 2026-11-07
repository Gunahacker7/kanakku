# Kanakku v1.1 — FINAL SPEC (EGM Phase 4: approved design)

**Features:** A. Recurring transactions · B. Budget alerts (80%/100%) · C. Biometric unlock
**Status:** FINAL — approved by Guna (decisions §0) on 2026-11-07. This document
supersedes `design_draft.md`; `concepts_brief.md` remains the rationale record.
Both Goldfish reviews (comprehension + antagonistic) returned GO-WITH-FIXES;
every mandatory fix from those reviews is folded into the normative text below.
**No code is authorised by this document alone** — implementation starts only
on Guna's explicit go-ahead after reading this spec.

**Hard constraints (unchanged):** offline build; **no new pub dependencies, no
new Gradle dependencies**; integer paise in all new data; v1.0.4 security
baseline (PBKDF2 PIN verifier, native counted failures + lockouts, Keystore
AES-256-GCM at rest, backup v2 passphrase format) is the floor; migrations
never lose a transaction.

---

## 0. Approver decisions (Guna, 2026-11-07 — all "recommended", with #4 as noted)

| # | Question | DECISION |
|---|---|---|
| 1 | Catch-up window for missed occurrences | **90 days — post ALL missed occurrences** up to 90 days back; older are `skipped` (§3.3 step 0). |
| 2 | Pause semantics | **Pause = SKIP.** Occurrences falling inside a pause are recorded `skipped` and are **never** caught up on resume (§3.5). |
| 3 | Overall budget | **ADD an explicit overall monthly cap setting** (paise-native, in Settings); overall alerts are OFF until the user sets it. Per-category alerts ship as designed (§4). |
| 4 | Biometric during PIN lockout | **NOT allowed. Lockout = PIN only.** While a PIN lockout timer is running, biometric unlock is **suspended**; it resumes when the lockout expires or a counted PIN verification succeeds. (This overrides the Elephant's "recommended yes" and adopts the security Goldfish's position.) |
| 5 | App-open-only evaluation | **ACCEPTED for v1.1.** Budget-alert evaluation and recurring posting run on app open / resume / data change only. Crossings are detected at the **next app open**, not in real time. Stated honestly in UI copy (§4.5) and in the first alert notification. |
| 6 | Prompt-only biometric risk | **ACCEPTED as a documented risk.** Biometric auth is prompt-only (no auth-bound Keystore key), so a **newly enrolled device fingerprint also unlocks Kanakku**, and the app cannot detect enrollment changes. The PIN encrypts nothing in the existing model. Accepted risk, recorded in §5.5; the auth-bound-Keystore-key redesign is the documented long-term fix (out of scope). |
| 7 | `matchOrPost` grace window | **Default 3 days** (bounded 0–14, §2.1). |

**Consequences of #4 that implementers must not miss:** §5.4's gate logic and
test T-C5 are written for the *suspended-during-lockout* behaviour. Any code
path that offers the biometric prompt while `PinStore` reports an active
lockout is a spec violation.

---

## 1. Architecture grounding (what exists, what we extend)

| Concern | Existing mechanism | v1.1 extension |
|---|---|---|
| Persistence | JSON documents in Kotlin `CaptureStore` (SharedPreferences, encrypted via `StoreCrypto`), one key per document | 2 new documents: `recurring_store`, `alert_state_store` |
| Dart↔native | `MethodChannel('in.kanakku/capture')` in `app/lib/capture.dart` (`CaptureService`), handlers in `MainActivity.kt` | New get/set pairs + biometric + budget-alert methods on the same channel |
| Transactions (captured) | Re-parsed per load in `CaptureService.loadTransactions()`, deduped by `ParsedTransaction.dedupeKey` = `amount(2dp)\|last4\|upiRef` | Unchanged as a data source; the recurring engine additionally **groups** captures before matching (§3.2) |
| Transactions (manual) | `manual_store` JSON list, shape `{amount(double ₹), label, ts, dir?, note?, category?, bucket?, mode?, tag?}`; entry id = hash of `manualRawBody(ts, dir, label)` | Generated entries add keys (§2.2) under the atomic dual-amount rule (§1.1) |
| Budgets | `budgets_store`: `{categoryName: capDoubleRupees}` decoded in `app/lib/budgets.dart` | Format **unchanged**; caps converted to paise at read |
| Notifications | `SummaryNotifier.kt`: framework `Notification.Builder`, AlarmManager, own channel | New `BudgetNotifier.kt` cloned from that pattern, own channel `kanakku_budget_alerts` |
| App lock | `_AppGateState` in `app/lib/main.dart`; native `PinStore` (PBKDF2, counted failures, lockout 30 s→900 s); locks on cold start + resume past background threshold | Biometric prompt inserted in the lock screen only, subject to §5.4 (incl. lockout suspension, decision #4) |
| Backups | `app/lib/backup.dart`, `backupStoreKeys`, envelope format v1 / encrypted v2 (passphrase, `BackupCrypto.kt`) | `'recurring'` added to `backupStoreKeys` with the restore rules of §6.2; alert state deliberately excluded |

### 1.1 Money representation rules (normative)

- All v1.1-owned values are `int` **paise**; field names end in `Paise`.
- The single conversion boundary lives in `app/lib/money.dart` (new, tiny):
  `int paiseFromRupees(double r) => (r * 100).round();`
  `double rupeesFromPaise(int p) => p / 100;`
  No other v1.1 code may multiply/divide money by 100.
- **Dual-amount invariant (normative, reviewer-mandated):** wherever a manual
  entry carries `amountPaise`, it MUST also carry `amount` (double rupees),
  and the two MUST be written **atomically in the same object write**:
  `amount = rupeesFromPaise(amountPaise)`. This holds on **every** write path —
  engine generation, user create, **and user edit**: any edit of an entry that
  changes its amount MUST recompute `amountPaise` from the edited `amount` in
  the same write (and vice versa). No code path may write one field without
  the other. Rationale: v1.0.4's decoder reads `amount` (downgrade safety,
  §6.3) while v1.1 totals prefer `amountPaise`; a partial write makes the
  ledger and the UI silently disagree.
- Loader rule (single point): wherever a manual entry's amount is read, use
  `entry['amountPaise'] ?? paiseFromRupees(entry['amount'])`.

### 1.2 The double-count invariant (normative)

> **Each real payment is counted exactly once in every total, at all times.**

Idempotent *posting* (deterministic ids) is necessary but not sufficient: the
capture layer can surface one real payment twice (SMS + notification twins
with different/absent UPI refs produce different `dedupeKey`s). The engine
therefore defends the invariant at match time (§3.2 grouping + ambiguity
flagging). Deterministic assignment is never claimed as correctness.

---

## 2. Data model changes

### 2.1 New document: `recurring_store` (CaptureStore key `recurring_store`)

Default: `{"nextRuleSeq": 1, "rules": []}`. `nextRuleSeq` is a **persisted
monotonic counter** — rule ids are `'rec_' + base36(createdAtMs) + '_' +
(nextRuleSeq++)`; the counter is never derived from the rules list (deletions
must never make an id reusable; a reused id would alias a deleted rule's
deterministic entry ids).

```jsonc
{
  "nextRuleSeq": 7,
  "rules": [
    {
      "id": "rec_m3k9x2_1",
      "label": "House Rent",
      "matchText": "LANDLORD NAME",     // counterparty text for capture matching; defaults to label; see §3.2 for empty-text rule
      "amountPaise": 1500000,           // int, > 0 — the rule's CURRENT amount (future occurrences)
      "dir": "debit",                   // "debit" | "credit"
      "category": "Rent",
      "bucket": "needs",                // "needs" | "wants" | "savings"
      "mode": "Bank Transfer",          // paymentModes from settings.dart; "Cash" drives policy default
      "accountLast4": "2482",           // optional, nullable; used in matching when set
      "note": null,                     // propagated to generated entries (§2.2)
      "interval": {
        "type": "monthly",              // "daily" | "weekly" | "monthly" | "customDays"
        "every": 1,                     // int >= 1
        "weekday": null,                // weekly only: 1=Mon..7=Sun
        "dayOfMonth": 5                 // monthly only: 1..31, clamped per month at firing
      },
      "startDate": "2026-11-05",        // yyyy-mm-dd, first possible due date
      "endDate": null,                  // nullable yyyy-mm-dd; occurrence > endDate never fires
      "maxCount": null,                 // nullable int >= 1; cap on FIRED occurrences (definition §3.4)
      "firedCount": 0,                  // MONOTONIC, persisted on the rule; incremented exactly once when an occurrence leaves `pending` for `posted` or `matched`. NEVER derived from the occurrences list; NEVER decremented or pruned.
      "lastFiredDate": null,            // yyyy-mm-dd of the most recent firing, or null
      "status": "active",               // "active" | "paused" | "ended"
      "capturePolicy": "matchOrPost",   // "auto" | "matchOrPost" (credit rules: §3.6)
      "graceDays": 3,                   // int, BOUNDED 0..14 (decision #7 default 3); UI clamps, engine clamps again on read
      "restoredHold": false,            // true after a backup restore until the user reviews (§6.2); engine treats held rules as paused
      "createdAt": 1794000000000,
      "updatedAt": 1794000000000,
      "occurrences": [                  // newest last; pruning per §2.1.1
        {
          "date": "2026-11-05",         // due date, yyyy-mm-dd (local)
          "amountPaise": 1500000,       // SNAPSHOT of the rule's amountPaise AT OCCURRENCE CREATION. Matching (§3.3) uses THIS field exclusively — never the rule's live amountPaise.
          "state": "posted",            // pending|posted|matched|skipped|flagged|resolved
          "entryId": "…",               // manual-store id when state=posted/flagged/resolved
          "captureKey": null,           // dedupeKey of the grouped capture when state=matched
          "resolvedAt": 1794000000000
        }
      ]
    }
  ]
}
```

Invariants: dates are **local calendar dates** (`yyyy-mm-dd` strings), never
timestamps. Unknown keys on read are ignored; missing optional keys default
as in the current manual-entry decoders (defensive decode, never throw).

#### 2.1.1 Occurrence pruning (normative)
Prune on each store write, per rule, keeping an occurrence if **any** holds:
- its state is `pending` or `flagged` — **never pruned**, regardless of age; or
- its `date` is within the last **45 days** (floor strictly above the 35-day
  late-match sweep window, §3.3 step 4); or
- it is among the **60 most recent** occurrences of the rule.
`firedCount`/`lastFiredDate` live on the rule (§2.1) precisely so pruning can
never affect `maxCount` enforcement or schedule math.

### 2.2 Changed document: `manual_store` (additive keys on generated entries only)

Generated entries are ordinary manual entries plus:

| Key | Value | Notes |
|---|---|---|
| `amount` | double ₹ | **Mandatory** alongside `amountPaise` — written atomically per §1.1 |
| `amountPaise` | int | Authoritative amount where present |
| `origin` | `"recurring"` | Absent on human entries |
| `recurringId` | rule id | |
| `occurrenceDate` | `yyyy-mm-dd` | The due date. Entry `ts` = due date at 12:00 local, so ordering vs same-day captures is stable and catch-up entries are never future-dated. The detail view also shows the posting date ("Posted 12 Nov") for back-posted entries, so retroactive history changes are visible, never silent. |
| `note` | rule's `note` at generation time | Propagated; absent if the rule has none |
| `editedByUser` | `true` once the user edits any field post-generation | Written by the existing edit path when `origin == "recurring"`; gates auto-delete in reconciliation (§3.3 step 4) |

The entry's rawBody (hence id) is deterministic:
`Recurring <ruleId>|<occurrenceDate>|<dir>|<label>` via a new
`recurringRawBody(...)` beside `manualRawBody` in `app/lib/manual.dart`.
A user-deleted generated entry leaves its occurrence in state `posted` with a
dangling `entryId`: the sweep (§3.3 step 4) MUST treat a missing entry as
"nothing to delete" and leave the occurrence untouched (no re-post, ever —
consistent with §3.7's matched-capture rule).

### 2.3 New document: `alert_state_store` (default `{}`)

```jsonc
{
  "2026-11": {                          // budget-month key, §4.2
    "cat:Groceries":  { "80": 1794000000000, "100": null, "capPaise": 300000 },
    "cat:Travel":     { "80": 1794100000000, "100": 1794200000000, "capPaise": 500000 },
    "__overall__":    { "80": null, "100": null, "capPaise": null }
  },
  "_meta": {
    "notifiedCountByDate": { "2026-11-07": 2 },
    "suppressedCrossings": [ { "key": "cat:Travel", "threshold": 100, "month": "2026-11", "date": "2026-11-07" } ],
    "bannerDismissedOn": null
  }
}
```

Semantics (normative — this replaces the draft's undefined `_meta` fields;
`lastNotifiedAt` is **removed**, nothing used it):
- Per key (`cat:<categoryName>` or `__overall__`): `"80"`/`"100"` hold the
  fire timestamp (ms) or null; **`capPaise` holds the last-seen cap** used by
  the §4.1 re-arm rule. A key's entry is created on first evaluation of that
  key in that month.
- `notifiedCountByDate`: map of local date (`yyyy-mm-dd`) → count of
  budget-alert **notifications actually posted** that day. This — and only
  this — enforces the 2-per-day cap (§4.3 rule 2). Dates older than 7 days
  are pruned on write.
- `suppressedCrossings`: crossings whose state fired but whose notification
  was suppressed by the daily cap (§4.3 rule 2). Consumed (read + cleared) by
  the next in-app banner (§4.4). Pruned with their month.
- `bannerDismissedOn`: local date the Home banner was last dismissed, or null.
- Months older than the previous budget month are pruned on write.
- **Not backed up** (derived state; restoring stale fired-flags could
  silently suppress alerts on a new phone — it re-evaluates fresh, §6.2).

**Category rename/delete (normative):** caps and alert state are keyed by
category **name**, so the Categories editor MUST, in the same user action:
- **Rename:** move the `budgets_store` cap to the new name AND rename the
  `cat:<old>` key to `cat:<new>` in the **current** budget month's alert
  state (older months are pruned anyway). Generated/manual entries keep their
  stored category string — rename of entry categories follows whatever the
  existing editor already does today; v1.1 adds no new behaviour there.
- **Delete (cap removed):** delete the cap AND delete the `cat:<name>` alert
  state for the current month. A category later re-created with the same
  name therefore starts with clean state and CAN alert (no inherited
  suppression). If a cap is deleted and re-added at a different value, §4.1's
  re-arm comparison uses the freshly created `capPaise` (no stale baseline).

### 2.4 Settings document additions (`settings_store`, via `app/lib/settings.dart`)

| Field | Type | Default | Purpose |
|---|---|---|---|
| `overallMonthlyCapPaise` | int? | null | Feature B overall cap (decision #3); null = overall alerts off |
| `budgetAlertsOn` | bool | true | Master switch for B notifications (in-app banners still show) |
| `biometricUnlock` | bool | false | Feature C toggle; force-false on load if no PIN is set |

All decode with defaults when absent → v1.0.4 settings docs load unchanged.

### 2.5 CaptureStore / channel additions

Kotlin `CaptureStore.kt`: keys `KEY_RECURRING = "recurring_store"`,
`KEY_ALERT_STATE = "alert_state_store"` + accessors mirroring `budgets()`.
`MainActivity.kt` channel methods (all failure-safe, Dart side defaults on error):

```
getRecurring / setRecurring          (String JSON, commit-write like setManual)
getAlertState / setAlertState        (String JSON)
postBudgetAlert {title, body}        -> bool   (BudgetNotifier)
biometricStatus                      -> String enum (§5.2)
biometricPrompt {title, subtitle}    -> bool   (async, §5.3)
```

`wipeAll` must clear both new documents (extend `CaptureStore.clearAll` list).

---

## 3. Feature A — Recurring transactions

### 3.1 Screens & flows
- **New screen "Recurring"** (Settings + Home shortcut chip): list of rules
  (label, amount, human schedule "Monthly on the 5th", status pill, next due),
  tap → rule detail (edit, pause/resume, end, delete, occurrence history,
  flagged-duplicate resolution rows, restored-rule review rows §6.2),
  **"+"** → create form: label, amount (₹ input → paise), direction,
  category/bucket (existing pickers), mode, account last4 (optional),
  interval picker, start date, optional end (date or count), capture policy
  (pre-selected by mode, changeable; credit rules §3.6), grace days
  (advanced, default 3, clamped 0–14).
- **Create-from-entry:** long-press any transaction → "Repeat this" pre-fills
  the form (amount, label as matchText seed, category, mode).
- Deleting a rule never deletes posted entries; ending keeps history visible.
- The Recurring screen also surfaces **possible refunds**: unmatched captured
  credits whose counterparty contains a rule's `matchText` are listed as
  "Possible refund?" rows (informational only; no auto-linking, §3.7).

### 3.2 Capture grouping & the canonical match test (normative)

**Grouping (before any matching):** the engine first groups the loaded
captures by **(amountPaise, accountLast4, localDate)**, where amountPaise =
`paiseFromRupees(capture.amount)`. Captures in one group are candidate twins
of a single real payment (e.g. the same payment seen via SMS and via
notification under different UPI refs). Matching operates on groups, not raw
captures:
- When an occurrence matches a group, **one** capture is consumed (record its
  `dedupeKey` as the occurrence's `captureKey`); the engine records the whole
  group as claimed by that occurrence.
- If, after an occurrence is matched, **another unmatched group** (different
  group, same amount, overlapping window) also satisfies the match test for
  the same occurrence, that is **ambiguity**: the occurrence goes to
  `flagged` for one-tap user resolution instead of silently consuming either
  group. If a second capture *within the same group* exists, it is a twin —
  not ambiguity — and is simply part of the claimed group.
- A capture/group may satisfy **only one occurrence across all rules**
  (consumed set built during the pass; ties broken by earliest due date).
  This constraint applies identically in step 1 (pending resolution) and
  step 4 (late-match sweep).

**Canonical match window (the ONLY definition; all steps reference this):**
for an occurrence with due date `D` and rule grace `g` (0–14), a capture
with local date `C` is in-window iff
**`D − 3 days ≤ C ≤ D + g days`**. (Early side is a constant 3 days — paid
early happens; the late side is the grace window.) No other window exists
anywhere in the engine; the late-match sweep widens nothing, it only re-runs
this same test for already-posted occurrences.

**Match test** — a group matches an occurrence iff ALL hold:
1. direction equal;
2. group amountPaise == **occurrence.amountPaise (the snapshot, §2.1)** —
   never the rule's live `amountPaise`;
3. rule.accountLast4 == null, OR group last4 == rule.accountLast4;
4. counterparty test: the capture's counterparty, if present, contains
   `matchText` (case-insensitive substring — matching is *containment*, and
   no stronger "fuzzy" quality is claimed anywhere in UI copy). If the
   capture has **no counterparty**, this clause passes (amount+direction+
   last4+window alone) — a deliberate, documented widening.
   **`matchText` empty (after trim) matches NOTHING** — an occurrence with an
   empty matchText can never match a capture that HAS a counterparty; the
   create/edit form also blocks saving an empty matchText for a
   `matchOrPost` rule (fallback: pre-fill with the label; if the label is
   also empty, the rule must use policy `auto`).

**Strong vs weak match (for the sweep, §3.3 step 4):** a match is **strong**
iff paise equal AND last4 equal (both present) AND (upiRef present and equal,
OR counterparty exactly equal after trim+case-fold normalisation). Anything
else that passes the match test is **weak**.

### 3.3 Generation & reconciliation pass
One idempotent pass, `RecurringEngine.run(now)` in `app/lib/recurring.dart`,
invoked from the Shell after `loadTransactions()` completes: on cold start
(**after the app-lock gate has unlocked** — passes never run behind the lock),
on resume, and after any manual add/edit. The pass is skipped entirely while
a restore is in progress (§6.2 restore flag).
Order inside the pass — **the bounds come first** (this ordering is
normative; the draft's step order was a reviewer-caught bug):

0. **Bounds before everything.** For each rule being processed, enumerate
   candidate due dates ≤ today. Any due date **older than today − 90 days**
   (decision #1) is recorded as a `skipped` occurrence (snapshot amount
   recorded) and is NEVER posted, matched, or counted as fired. The 90-day
   bound therefore filters occurrence creation *before* any posting step can
   see the date. (One in-app notice per rule per pass: "N older occurrences
   skipped".)
1. **Resolve pending occurrences** (oldest due date first, across all
   processed rules): for each `pending` occurrence whose window (§3.2)
   includes today or has closed, run grouping + match test (§3.2). Match →
   occurrence `matched`, `firedCount++`, record `captureKey`. Ambiguity →
   `flagged` (§3.2). No match and today > D + g → step 2.
2. **Expire pending occurrences** past `D + graceDays` with no match → post
   the entry (§2.2, atomic dual-amount), occurrence `posted`, `firedCount++`.
3. **Create occurrences for due dates ≤ today** not yet recorded (and not
   already bounded out by step 0):
   - policy `auto` → post entry immediately, occurrence `posted`, `firedCount++`.
   - policy `matchOrPost` → occurrence `pending` with the **amount snapshot**,
     then step 1 logic applies in the same pass (a capture may already exist
     — e.g. paid early).
   - credit rules → §3.6 guard applies instead of automatic posting.
4. **Late-match sweep:** for occurrences in state `posted` with due date
   within the last **35 days**, re-run the §3.2 test (same canonical window,
   same one-capture constraint — a capture already recorded as another
   occurrence's `captureKey` is NOT available here):
   - **Strong match** and the generated entry is untouched (`editedByUser`
     absent) → remove the generated entry from `manual_store`, occurrence →
     `matched`. (The occurrence was already counted in `firedCount` at
     posting; the transition does not change it.)
   - **Weak match**, or strong match on a **user-edited** entry → occurrence
     → `flagged`; the Recurring screen shows a "Possible duplicate" row.
     **A weak/fuzzy match NEVER deletes a ledger entry** — deletion on a
     fuzzy match can erase a genuinely distinct same-amount payment
     (rent advance + regular rent), and a missing entry is invisible to the
     user, which is worse than a visible duplicate.
   - User resolution of a `flagged` occurrence (either kind): "Keep both" or
     "Remove generated" → occurrence → **`resolved`** (terminal; entryId kept
     for reference). `resolved` occurrences are never re-flagged or re-swept.
5. **Stop conditions:** after the pass, for each processed rule: if
   `endDate` has passed with no pending occurrences, or `firedCount >=
   maxCount` (when set), the rule auto-transitions to `ended`. A `pending`
   occurrence whose rule's `endDate` passes before resolution still resolves
   normally (it fired before the end); no NEW occurrences are created past
   `endDate`.
6. Persist `recurring_store` once at pass end (single commit write). Before
   posting any entry, check `manual_store` for the deterministic entry id;
   if present, record `posted` and do not re-add — a crash between
   entry-write and store-write heals on the next pass.

**Which rules the pass processes:** `active` rules, plus — on the first pass
after a resume — `paused` rules **solely** to record pause-skips (§3.5);
`ended` rules are never processed; `restoredHold` rules are treated as
paused (§6.2).

### 3.4 Schedule computation & `maxCount` semantics
`List<String> dueDates(Rule r, String fromExclusive, String toInclusive)` in
`app/lib/recurring.dart` — pure function over date strings.
- daily: every N days from startDate. customDays: alias with N > 1.
- weekly: every N weeks on `weekday` (first fire = first such weekday ≥ startDate).
- monthly: every N months on `min(dayOfMonth, lastDayOfMonth)` — clamp per
  month, computed from the *nominal* day each time (31 → Feb 28/29 → Mar 31;
  no permanent drift).
- **"Fired" (normative, for `maxCount`):** an occurrence counts as fired
  exactly when it transitions out of `pending` into `posted` or `matched`,
  recorded by the persisted monotonic `firedCount` (§2.1). Occurrences
  `skipped` for ANY reason (90-day bound, pause) do **not** consume
  `maxCount`. Counts are NEVER derived from the (pruned) occurrences list.

### 3.5 Pause semantics (decision #2)
Pausing takes effect immediately for un-fired due dates. On the first pass
after a rule is resumed (or on the pass that first observes the pause span),
each due date that fell inside the pause is recorded as a `skipped`
occurrence (snapshot amount recorded, no entry, no match attempt, no
`firedCount` change). **Skipped-in-pause occurrences are never caught up.**
An occurrence already `pending` when the rule is paused stays `pending` and
resolves normally after resume (it fired before the pause).

### 3.6 Credit (income) rules — phantom-income guard (normative)
Exact-paise matching fails precisely for salary (net pay varies: arrears,
deductions), and a fallback-posted credit that later coexists with the real
salary capture **overstates available money** — worse than an overstated
expense. Therefore:
- Credit rules **cannot** use plain `auto`, and `matchOrPost` for a credit
  rule is the **confirm-before-posting** variant: when the grace window
  closes with no match, the engine does NOT post. It creates a `flagged`
  occurrence surfaced as "Expected income not seen — post it manually?" with
  one-tap **Post** / **Skip**. Only the user's tap posts the credit.
- Matching for credits otherwise uses §3.2 unchanged (exact paise; no amount
  tolerance in v1.1 — tolerance matching is a v1.2 candidate). If a capture
  matches, the occurrence is `matched` exactly like debits.
- T-R14's expectation is updated accordingly (§7).

### 3.7 Interaction with the rest of the app
- Generated entries appear in Transactions with a small "↻ Recurring" tag
  and are otherwise **ordinary manual-store entries in every respect**: they
  count in Home, Insights, budgets and exports, and they participate in
  splits **identically to human manual entries** (the splits feature itself
  is untouched; no exclusion). Category/bucket come from the rule.
- **Reversal handling:** a captured refund/credit is never auto-linked to an
  occurrence (documented limitation; §3.1 surfaces "Possible refund?" rows).
  If a *matched* capture is later removed by the user via the existing
  removed-store flow, the occurrence stays `matched` — the rule never
  re-posts (prevents resurrection loops).

### 3.8 Remaining edge cases (explicit)
- Rule amount edited → future occurrences use the new amount; a `pending`
  occurrence keeps its snapshot (§2.1) for both matching and posting.
- Rule deleted with a `pending` occurrence → pending is discarded silently.
- Clock/timezone travel: all logic on local date strings; a date-line
  crossing can at worst delay a posting by a day, never duplicate
  (deterministic ids + per-attempt existence check in step 6).
- SMS store is capped (rolling 500): a matched capture's SMS may age out and
  the capture vanish from `loadTransactions()`. The occurrence record is the
  source of truth — nothing re-posts. ✔ by design (step 4 sweeps only
  `posted` occurrences younger than 35 days, and only toward `matched`).

---

## 4. Feature B — Budget alerts (80% / 100%)

### 4.1 Evaluation
`BudgetAlerts.evaluate(...)` in new `app/lib/budget_alerts.dart`, called:
after `loadTransactions()` + recurring pass, after manual add/edit/delete,
after any budget cap edit, after `overallMonthlyCapPaise` changes.
**When it runs is the whole story (decision #5): evaluation happens only
while the app is open.** A crossing caused by an SMS that arrives while the
app stays closed is detected at the next open — this is inherent to the
architecture (no Dart runs in the background) and is stated to the user
(§4.5), never hidden.

Inputs: per-category spent (paise, current budget month), caps (paise,
converted at read), overall spent/cap.
**Overall spent (normative composition):** the sum of **debit** amounts of
all transactions (captured + manual, generated included) in the budget
month, **regardless of category** (uncategorised included), with two
exclusions: (a) credits/income never net against it; (b) debits whose bucket
is `savings` are excluded (they are allocations, not consumption). Per-
category spent follows the existing Budgets-screen definition for that
category (debits in the category; generated credits in a category do not net
against that category's spent in v1.1).

For each category with cap > 0 (and for `__overall__` if its cap is set):
`pct = spent * 100 ~/ cap` (integer math only). For thresholds 100 then 80:
- if `pct >= t` and state[t] is null → **fire**: record timestamp, queue for
  notification (§4.3).
- **Re-arm:** if `pct < t` and state[t] is set → clear state[t] **only if**
  the key's stored `capPaise` (§2.3) differs from the cap used in this
  evaluation (i.e. the drop is due to a cap change); then update `capPaise`
  to the current cap. Spend decreases alone (entry deleted) do **not**
  re-arm within the month — prevents delete-and-respend notification loops.

### 4.2 Budget month
Month key = the app's existing budget-month bucketing driven by
`monthStartDay` in settings (same function the Budgets screen uses — reuse,
do not re-implement). Key format `yyyy-mm` of the bucket's *start* date.

### 4.3 Notification rules (anti-spam, normative)
1. At most **one** notification per evaluation; it aggregates all crossings
   fired in that evaluation: title "Budget alert", body lists up to 3:
   "Groceries crossed 100%", "Travel crossed 80%" (+ "+2 more"). The
   **first-ever** budget-alert notification additionally carries the honesty
   line: "Alerts are checked when you open Kanakku" (§4.5).
2. At most **2** budget-alert notifications per calendar day, enforced by
   `_meta.notifiedCountByDate` (§2.3). **A third (or later) same-day
   crossing is NOT dropped silently and NOT queued as a notification:**
   its state fires and is recorded (so it can never notify later either),
   no notification is posted that day, and the crossing is appended to
   `_meta.suppressedCrossings`, which the **next in-app banner** (§4.4)
   surfaces by name and count. The user therefore always learns about a
   suppressed 100% breach in-app, and the notification ledger can be
   audited against `notifiedCountByDate`.
3. No notification when `budgetAlertsOn == false` (state still records → no
   burst when re-enabled; suppressed-notification bookkeeping is skipped —
   rule 2 concerns the daily cap only).
4. No notification is posted while the app is in the **foreground** (the
   user is already looking at the banner); state + banner still update.
5. Channel `kanakku_budget_alerts`, IMPORTANCE_DEFAULT. Content visibility
   SECRET: lock screen shows "Budget alert — open Kanakku"; content shows
   percentages only, never amounts or balances (audit F12 pattern).
6. Notification permission: reuse existing `requestNotificationPermission`
   flow; if denied, in-app only, no repeated asks.

### 4.4 UI
- Budgets screen: rows show % used; threshold ticks at 80% on the progress
  bar and a fired-state dot; the screen **header carries the line "Alerts
  are checked when you open the app"** (§4.5).
- Settings → "Budget alerts" toggle + "Overall monthly budget" field
  (₹ → paise) + the same honesty note.
- Home: a dismissible banner lists **today's crossings not yet acknowledged
  in-app** — i.e. crossings fired today (any evaluation) plus any
  `suppressedCrossings` (§4.3 rule 2) — until dismissed; dismissal writes
  `_meta.bannerDismissedOn` (§2.3). Suppressed crossings remain listed until
  the banner is dismissed once with them visible.

### 4.5 Honesty wording (normative copy)
Wherever alerts are described (Budgets header, Settings note, first
notification), the wording is: **"Budget alerts are checked when you open
Kanakku — not in real time."** No screen, store listing, or notification may
describe v1.1 alerts as real-time.

---

## 5. Feature C — Biometric unlock

### 5.1 Dependency verdict (blocker, resolved by design)
`local_auth` is absent and cannot be added (offline build, zero-plugin
pubspec). Design uses **framework** APIs only:
- `android.hardware.biometrics.BiometricPrompt` (API 28+) — the v1.1 path.
- Manifest: add `<uses-permission android:name="android.permission.USE_BIOMETRIC"/>`
  (normal permission). No Gradle changes (framework classes only;
  implementation detail: executor via `context.mainExecutor` on API 28+).

**API 24–27 = PIN only (decided, not deferred silently):** the
device-credential route (`KeyguardManager.createConfirmDeviceCredentialIntent`)
does **not** ship in v1.1. On API < 28 the biometric toggle is shown as
unavailable with the explanation in §5.2. This corrects the concepts brief,
which had recommended the device-credential fallback inside v1.1 — the cut
is explicit here and in §8 so the approver's record is accurate.

### 5.2 Capability probe — channel `biometricStatus` → exactly one of:
`available` (hardware + enrolled + device secure) · `noneEnrolled` ·
`noHardware` · `noDeviceLock` · `unsupportedApi` (API < 28 → toggle shown
unavailable with the explanation "Fingerprint unlock needs Android 9 or
newer on this phone; your PIN still protects the app."). Probe uses
`BiometricManager.from(ctx).canAuthenticate(BIOMETRIC_STRONG)` where
available (framework API 29+); on API 28 falls back to
`FingerprintManager.hasEnrolledFingerprints()` (deprecated, functional).

### 5.3 Prompt flow — channel `biometricPrompt`
Native builds `BiometricPrompt` with title "Unlock Kanakku", subtitle
"Use fingerprint or face", negative button "Use PIN". Callbacks map to:
success → `true`; ERROR_USER_CANCELED / negative → `false` + Dart shows PIN
pad; ERROR_LOCKOUT / ERROR_LOCKOUT_PERMANENT → `false` + PIN pad (system
enforces its own biometric lockout); any other error → `false` (fail-closed).
**Precondition (decision #4):** Dart MUST NOT invoke `biometricPrompt` while
a PIN lockout is active (§5.4) — the prompt is not offered at all in that
state, so the mapping above never races the lockout rule.

### 5.4 Gate integration (`_AppGateState`, `_LockScreen` in `main.dart`)
- When the gate locks and `biometricUnlock && pinSet && status == available`
  **and no PIN lockout is active**: show the biometric prompt automatically
  once; the PIN pad is visible beneath/behind with an explicit "Use PIN"
  affordance and a "Try biometrics again" icon button. The PIN entry path is
  byte-for-byte the existing one (counted verify + lockouts untouched).
- **Lockout suspension (decision #4, normative):** while `PinStore` reports
  an active lockout, biometric unlock is **suspended**: the lock screen
  shows the PIN pad with the lockout countdown and **no** biometric prompt,
  auto-prompt, or "try biometrics" button. Biometric availability resumes
  automatically when the lockout expires or a counted PIN verification
  succeeds. Biometric failure/success never touches the PIN failure
  counters. (Biometric success while NOT in lockout does not reset PIN
  failure counters either — counters are PIN-path state only.)
- Timeout: **no change** — biometrics are offered exactly when the PIN pad
  would appear (cold start; resume after the existing background threshold).
- Balance-reveal and Settings PIN prompts: unchanged (PIN only) in v1.1.
- Settings → App lock: "Unlock with biometrics" toggle. Enabling requires a
  successful counted PIN verification, then a live probe (must be
  `available`), then one successful prompt; only then persist
  `biometricUnlock = true`. Disabling requires counted PIN verification.
  If PIN is cleared/disabled anywhere, the gate forces `biometricUnlock=false`.
- Fail-closed everywhere: channel timeout/exception → PIN pad, never unlock
  (preserves the v1.0.4 F13 fix).

### 5.5 Security notes (corrected — read carefully)
- **Correction of the draft's claim:** the draft stated the v1.0.4 baseline
  is "not weakened". That claim is **withdrawn**. Precise position: the lock's
  effective strength becomes *min(PIN-with-counted-lockout,
  device-biometrics-with-enrollment-blindness)*. For the audit's adversary
  (a) — a person holding the unlocked phone briefly — prompt-only biometrics
  grant something v1.0.4 never granted: after one enrollment moment in
  Android Settings (which needs the *device* credential, not Kanakku's PIN),
  that person has **persistent, silent access** to Kanakku; the app cannot
  detect the new enrollment, and the PIN counters never move. Decision #4
  (no biometric bypass of an active PIN lockout) removes the lockout-bypass
  half of that weakening; the enrollment-blindness half remains and is the
  accepted risk of decision #6. The long-term fix is an auth-bound Keystore
  key (`setUserAuthenticationRequired`), which makes enrollment changes
  invalidate the key — recorded here as the v1.2+ direction, out of scope.
- Biometric in v1.1 is therefore a **convenience verifier for the privacy
  lock**, and Settings copy MUST say: "App lock keeps casual viewers out.
  Anyone who can unlock this phone — including a fingerprint added later —
  can open Kanakku." (Exact honesty wording; do not soften.)
- The v1.0.4 baseline is otherwise preserved exactly: PBKDF2 verifier,
  counted failures shared by all PIN prompts, 30 s→900 s lockouts, no reset
  hatch, fail-closed gate. Biometrics add a parallel *verifier*, never a
  parallel *reset* or *recovery* path.
- No biometric data or templates are ever accessible to the app — the system
  prompt returns only success/failure. Nothing biometric is stored, logged,
  or backed up; the backed-up `biometricUnlock` flag is inert on a new
  device until the probe passes and the user re-enables via PIN.
- At-rest model unchanged: the data key is a device Keystore key not bound
  to user authentication; the PIN likewise encrypts nothing (audit F3/F7
  context). v1.1 does not change that model.

---

## 6. Migration & backup/restore

### 6.1 Migration (v1.0.4 → v1.1) — following the `migrated_v104` precedent
Native flag `KEY_MIGRATED_V110 = "migrated_v110"` in CaptureStore prefs.
On first v1.1 launch (Dart init, before the Shell loads), idempotent steps:
1. If `recurring_store` doc absent → write `{"nextRuleSeq": 1, "rules":[]}`.
   Same for `alert_state_store` → `{}`.
2. Settings doc: no rewrite (new fields default at decode).
3. Budgets doc: no rewrite (conversion at read).
4. `manual_store`: **no rewrite** — generated-entry keys are additive and
   written only for new entries; legacy entries load via existing defaults.
5. Set `migrated_v110`. Re-running the whole sequence is a no-op (safe after
   a crash mid-migration; there is no destructive step to resume).

**No existing transaction is touched, re-keyed, or re-written by migration.**

### 6.2 Backup & restore (normative — the destructive path is specified, not tested-into-existence)
`backupStoreKeys` += `'recurring'`. Backups stay v2-passphrase format;
format version unchanged (store keys are additive inside the envelope).
Alert state is never backed up (§2.3).

**Absent-key rule (decided):** a key absent from the backup means **"leave
the current store untouched"** for that key. Restoring a v1.0.4 backup into
v1.1 therefore leaves any existing v1.1 rules in place (they are NOT wiped),
and restoring into an empty v1.1 leaves the default empty rules doc.
Rationale: the opposite branch silently destroys user data on the most
common restore (an old backup), and rule-vs-ledger staleness is handled by
the hold below rather than by deletion.

**Restore hold (normative, reviewer-mandated):** whenever a restore writes
the `recurring` key, EVERY restored rule is imported with
`restoredHold = true` and `status` preserved-but-inert (the engine treats
held rules exactly like paused ones — §3.3), and every restored occurrence
with a due date **before the restore date** is rewritten to state `skipped`
at import time (its entryId/captureKey are kept for reference). Nothing
back-posts from a restore — the 90-day catch-up (§3.3 step 0) can never fire
on restored history, because those occurrences arrive already `skipped`.
The Recurring screen shows one review row per held rule — "Restored rule —
Resume / Keep paused / Delete" — and the user's choice clears
`restoredHold` (Resume also sets `status = active`; occurrences due on or
after the restore date then behave normally). This closes the attack where
restoring an old backup resurrects a deleted rule that mass-back-posts
against a ledger already containing the real payments (deterministic ids do
not protect there: the user's replacement entries have different rawBodies).

**Crash-mid-restore (normative):** restores write per-document commits, so a
kill mid-restore can leave a mixed-generation store set. A
`restore_in_progress` flag (settings doc, set before the first restore
write, cleared after the last) MUST be respected by the recurring engine and
by alert evaluation: while set, both are skipped. On the next launch, if the
flag is found set, it is cleared and the restore-hold import treatment is
applied to the `recurring` doc as found (held + pre-restore occurrences
skipped) before any pass runs — a half-restored rules doc is therefore
always quarantined, never reconciled live.

### 6.3 Downgrade safety
v1.0.4 ignores the two new documents and the additive manual keys, and —
because of the §1.1 atomic dual-amount rule — every generated entry carries
a valid double `amount`, so **v1.0.4 reads generated entries correctly and
corrupts nothing**. The only loss on downgrade is the rules themselves
(occurrences included) and the biometric flag. v1.1 reading v1.0.4 data is
the supported direction and is fully specified in §6.1.

---

## 7. Test checklist (Goldfish attack + implementation QA)

**Money & rounding**
- T-M1: ₹499.99 rule → 49999 paise everywhere; totals equal capture-side
  `499.99` double conversion exactly (no 49998/50000 drift).
- T-M2: cap ₹3,000.00 stored as double `3000.0` → 300000 paise; 80% fires at
  spent 240000, not 239999.
- T-M3: integer pct math: spent 1 paise over 80% of an odd cap (e.g. ₹333.33)
  fires; 1 paise under does not.
- **T-M4 (new):** edit a generated entry's amount → `amountPaise` recomputed
  in the same write; list view and totals agree on the new figure
  immediately (atomic dual-amount rule, §1.1).

**Recurring engine**
- T-R1: monthly day-31 rule: Jan 31 → Feb 28 (2027) / Feb 29 (2028) → Mar 31 (no drift).
- T-R2: weekly every-2-weeks across a month boundary; customDays N=10 across DST-free IST (no DST in India — verify no UTC conversion sneaks in).
- T-R3: app unopened 45 days, monthly rent rule → exactly 1 catch-up entry (plus current), each with correct occurrence `ts` (noon of due date).
- T-R4: catch-up > 90 days → older occurrences `skipped`, one in-app notice, no entries. **Plus:** rule created today with startDate 1 year in the past → first pass posts NOTHING older than 90 days (bound filters creation, §3.3 step 0).
- T-R5: run the pass twice back-to-back, and kill the app mid-pass → zero duplicate entries (deterministic ids).
- T-R6: `matchOrPost`: matching UPI capture on due date → occurrence `matched`, no entry; budget totals count the spend once.
- **T-R6b (new):** the SAME payment arriving via SMS and via notification with different UPI refs (two dedupeKeys, one §3.2 group) → occurrence `matched` once, group claimed once, spend counted once.
- **T-R6c (new):** two genuinely distinct same-amount payments to the same counterparty inside one window (two groups) for one occurrence → occurrence `flagged`, neither group silently consumed; user resolution consumes exactly one.
- T-R7: no capture within grace → entry posts the day after the window closes (day D+g+1 evaluation), dated at due date.
- T-R8: capture arrives 10 days after fallback posting, STRONG match (§3.2) → generated entry removed, occurrence `matched`, totals unchanged (counted once throughout).
- T-R9: same as T-R8 but user edited the generated entry's category → entry kept, occurrence `flagged`, duplicate-resolution row appears; both resolution choices verified; after resolution the occurrence is `resolved` and is never re-flagged on later passes.
- **T-R9b (new):** capture arrives after fallback posting, WEAK match only (e.g. no last4 on the capture) → entry is NOT auto-deleted; occurrence `flagged` (fuzzy deletion ban, §3.3 step 4).
- T-R10: two rules, identical amount + counterparty, overlapping windows → deterministic assignment (earliest due consumes the group); second rule posts after grace.
- **T-R10b (new):** a capture already recorded as rule X's `captureKey` is presented to rule Y's sweep → not consumed twice (§3.2 one-capture constraint in the sweep).
- T-R11: paused rule across 2 due dates → both `skipped`, nothing posts on resume; `firedCount` unchanged; a rule with maxCount does NOT auto-end from pause-skips (§3.4).
- T-R12: rule amount edited while an occurrence is `pending` → matching AND any fallback posting use the occurrence's **snapshotted** `amountPaise` (§2.1).
- T-R13: matched capture deleted by user → no re-post, ever.
- T-R14: credit rule (salary): matching salary credit capture → `matched`, income counted once. **Revised expectation:** with NO matching capture, the window closing produces a `flagged` "post manually?" occurrence and **no entry** until the user taps Post (§3.6) — a phantom credit must never appear.
- T-R15: maxCount=3 rule fires exactly 3 times then auto-`ended`.
- **T-R15b (new):** daily rule with **maxCount=30** fires exactly 30 times then auto-`ended` (defeats the old prune-the-count bug; `firedCount` is persisted, §2.1).
- **T-R16 (new):** daily rule: a `posted` occurrence 34 days old whose capture arrives late → sweep still matches it (pruning floor 45 days / 60 count, §2.1.1); a `flagged` occurrence older than 45 days is still present and resolvable (never pruned).
- **T-R17 (new):** `matchOrPost` rule saved with empty `matchText` → form blocks it (label fallback / policy forced to `auto`); a hand-crafted store with empty matchText matches NOTHING (§3.2).
- **T-R18 (new):** `graceDays` set to 0 and to 99 in a hand-crafted store → engine clamps to 0..14; grace 0 expires on the next pass after the due date.
- **T-R19 (new):** user deletes a generated entry → occurrence stays `posted` with dangling entryId; later passes neither re-post nor crash (§2.2).
- **T-R20 (new):** passes do not run while the app-lock gate is locked, and do not run while `restore_in_progress` is set (§3.3, §6.2).

**Budget alerts**
- T-B1: crossing 80 then 100 in separate evaluations → one notification each; repeated evaluations at same spend → zero repeats.
- T-B2: one evaluation crossing 3 categories → exactly 1 aggregated notification.
- T-B3: restore of a v1.0.4 backup → per §6.2: existing rules are **preserved** (absent-key rule) and any rules IN a v1.1 backup arrive **held** with pre-restore occurrences `skipped` — nothing back-posts; alert state re-evaluates fresh, no burst of >1 notification. **Plus:** kill the app mid-restore → next launch quarantines the rules doc (hold applied) before any pass runs.
- T-B4: cap raised mid-month dropping pct below 80 → flag re-arms (via stored `capPaise`, §2.3); re-crossing fires again (once).
- T-B5: entry deleted dropping pct → no re-arm; re-spend past threshold → no second notification this month.
- T-B6: `monthStartDay = 25`: crossing on the 24th belongs to the previous budget month; state does not reset on the 1st.
- T-B7: 3rd crossing in a day → state recorded, **no 3rd notification**, crossing appears by name in the next in-app banner via `suppressedCrossings`, and `notifiedCountByDate` shows exactly 2 for the day (§4.3 rule 2).
- T-B8: overall cap unset → no overall alert even if total spend is huge; set → fires at 80/100 of overall spent composed per §4.1 (uncategorised debits count; credits don't net; `savings`-bucket debits excluded).
- T-B9: alerts off → crossings recorded silently; re-enable → no catch-up burst.
- T-B10: lock screen shows redacted public text only (no amounts).
- **T-B11 (new):** rename a category with a fired 80% flag → cap and current-month alert state follow the new name (no lost flag, no double alert). Delete a cap, re-add the same category at a new value → state starts clean; alert can fire (§2.3).
- **T-B12 (new):** evaluation runs while the app is in the foreground → banner updates, no notification is posted (§4.3 rule 4); the first-ever notification contains the "checked when you open Kanakku" line (§4.3 rule 1).

**Biometric unlock**
- T-C1: API 35 + enrolled fingerprint: cold start → prompt → success unlocks; cancel → PIN pad; wrong PINs still lock out per existing schedule.
- T-C2: API 27 device (or emulator): toggle shows unavailable + the §5.2 reason; PIN flow untouched (PIN-only on API 24–27).
- T-C3: no enrolled biometrics / no device lock → probe states surface exact copy; toggle cannot enable.
- T-C4: enable flow: wrong PIN at the enable gate → counted failure (lockout machinery), toggle stays off.
- **T-C5 (revised per decision #4):** PIN lockout active → **biometric prompt is NOT offered** (no auto-prompt, no try-again button); PIN pad shows the countdown. After the lockout expires, biometrics are offered again. A counted PIN success during lockout also re-enables biometric offering.
- T-C6: PIN disabled in Settings → `biometricUnlock` forced false; re-setting a PIN does not silently re-enable biometrics.
- T-C7: channel forced to throw/timeout → PIN pad appears (fail-closed), app never opens unlocked.
- T-C8: system biometric lockout (5 bad fingers) → prompt error routes to PIN pad; Kanakku PIN counters unchanged.
- T-C9: backup restored on a second device → flag present but gate uses PIN until re-enabled via PIN + probe.
- **T-C10 (new):** Settings App-lock screen shows the §5.5 honesty copy verbatim, including the later-added-fingerprint sentence.

**Migration & compatibility**
- T-X1: real v1.0.4 stores (all document types populated) → v1.1 first launch: every transaction, budget and setting intact; migration runs once; second launch no-op.
- **T-X2 (extended, reviewer-mandated):** v1.1 backup **containing generated recurring entries** → restored into the **v1.0.4 app**: no crash, ledger intact, **generated entries present with correct amounts** (atomic dual-amount rule, §1.1/§6.3), rules absent.
- T-X3: `wipeAll` clears recurring + alert state + biometric flag with everything else.
- T-X4: offline build passes with **zero** changes to `pubspec.yaml` and Gradle dependency blocks; manifest diff = `USE_BIOMETRIC` only.
- **T-X5 (new):** downgrade → re-upgrade round trip: v1.1 → v1.0.4 (rules lost, ledger intact per T-X2) → v1.1 again: migration is a no-op over the surviving docs, no duplicate stores, no crash on the orphaned new documents.

---

## 8. Exact files to change (implementation map)

**New:** `app/lib/money.dart` · `app/lib/recurring.dart` ·
`app/lib/budget_alerts.dart` · `app/android/.../BudgetNotifier.kt`
**Dart edits:** `app/lib/capture.dart` (channel methods §2.5) ·
`app/lib/manual.dart` (`recurringRawBody`; `amountPaise`/`origin`/`note`
write+read; **edit path recomputes `amountPaise` atomically**, §1.1) ·
`app/lib/budgets.dart` (paise conversion at read) ·
`app/lib/categories.dart` **(rename/delete migrate cap + alert state, §2.3)** ·
`app/lib/settings.dart` (§2.4 fields) · `app/lib/backup.dart`
(`backupStoreKeys` += `'recurring'`; restore-hold import treatment +
`restore_in_progress` flag, §6.2) · `app/lib/main.dart` (Recurring screen,
gate biometric branch incl. lockout suspension §5.4, evaluation hooks —
insert at `_AppGateState`, `_LockScreen`, Shell load completion, Budgets
screen).
**Kotlin edits:** `CaptureStore.kt` (2 keys + accessors + clearAll) ·
`MainActivity.kt` (channel handlers §2.5, biometric probe/prompt) ·
`AndroidManifest.xml` (`USE_BIOMETRIC`).
**Untouched:** `parser/` (no parser changes needed), `PinStore.kt`,
`StoreCrypto.kt`, `BackupCrypto.kt`, `pubspec.yaml`, Gradle files.

## 9. Out of scope for v1.1 (explicit)
Custom alert thresholds · biometric for balance-reveal/Settings prompts ·
**device-credential unlock fallback (API < 28 is PIN-only, §5.1)** ·
refund-to-rule auto-linking · auth-bound Keystore data key ·
native background evaluation (alerts/recurring are app-open-only,
decision #5) · credit-rule amount-tolerance matching · Drift/SQLite
migration · iOS.
**Divergence from KANAKKU-SPEC §2.6 (explicit, reviewer-mandated):**
subcategory budgets and the 50/30/20 salary split specified in §2.6 are
**OUT OF SCOPE for v1.1**. v1.1 budgets are per-category caps on the existing
`budgets_store` plus the new overall cap (decision #3); buckets
(needs/wants/savings) continue to exist as entry metadata exactly as in
v1.0.4, but no split-ratio engine is built. This is a deliberate scoping
decision recorded here so nobody implements or approves against the spec's
wider reading; §2.6 remains the target for a later version.

---

*End of final spec. Implementation begins only on Guna's explicit approval
of this document (EGM rule: human approves the spec before code).*
