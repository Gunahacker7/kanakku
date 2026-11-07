> **SUPERSEDED — 2026-11-07:** This draft is superseded by `final_spec.md` in this folder (approver decisions + Goldfish fixes folded in). Do not implement from this document.

# Kanakku v1.1 — Design Draft (EGM Phase 2)

**Features:** A. Recurring transactions · B. Budget alerts (80%/100%) · C. Biometric unlock
**Decisions source:** `concepts_brief.md` (recommendations adopted; items marked
**[Guna-pending]** ship with the recommended default if he approves the spec as-is).
**Hard constraints honoured:** no new pub dependencies, no new Gradle dependencies,
integer paise in all new data, v1.0.4 security baseline (PBKDF2 PIN, Keystore
AES-256-GCM at rest, backup v2) not weakened, migrations never lose a transaction.

---

## 1. Architecture grounding (what exists, what we extend)

| Concern | Existing mechanism | v1.1 extension |
|---|---|---|
| Persistence | JSON documents in Kotlin `CaptureStore` (SharedPreferences, encrypted via `StoreCrypto`), one key per document | 2 new documents: `recurring_store`, `alert_state_store` |
| Dart↔native | `MethodChannel('in.kanakku/capture')` in `app/lib/capture.dart` (`CaptureService`), handlers in `MainActivity.kt` | New get/set pairs + biometric + budget-alert methods on the same channel |
| Transactions (captured) | Re-parsed per load in `CaptureService.loadTransactions()`, deduped by `ParsedTransaction.dedupeKey` = `amount(2dp)\|last4\|upiRef` | Unchanged; recurring engine *reads* this list |
| Transactions (manual) | `manual_store` JSON list, shape `{amount(double ₹), label, ts, dir?, note?, category?, bucket?, mode?, tag?}`; entry id = hash of `manualRawBody(ts, dir, label)` | Generated entries add optional keys (§3.2); loader prefers `amountPaise` when present |
| Budgets | `budgets_store`: `{categoryName: capDoubleRupees}` decoded in `app/lib/budgets.dart` | Format **unchanged**; caps converted to paise at read |
| Notifications | `SummaryNotifier.kt`: framework `Notification.Builder`, AlarmManager, own channel | New `BudgetNotifier.kt` cloned from that pattern, own channel `kanakku_budget_alerts` |
| App lock | `_AppGateState` in `app/lib/main.dart`; native `PinStore` (PBKDF2, counted failures, lockout 30 s→900 s); locks on cold start + resume past background threshold | Biometric prompt inserted in the lock screen only |
| Backups | `app/lib/backup.dart`, `backupStoreKeys`, envelope format v1 / encrypted v2 (passphrase, `BackupCrypto.kt`) | `'recurring'` added to `backupStoreKeys`; alert state deliberately excluded |

**Money representation rule (applies everywhere below):**
- All v1.1-owned values are `int` **paise**, field names end in `Paise`.
- The single conversion boundary lives in `app/lib/money.dart` (new, tiny):
  `int paiseFromRupees(double r) => (r * 100).round();`
  `double rupeesFromPaise(int p) => p / 100;`
- No other v1.1 code may multiply/divide money by 100.

---

## 2. Data model changes

### 2.1 New document: `recurring_store` (CaptureStore key `recurring_store`, default `{"rules":[]}`)

```jsonc
{
  "rules": [
    {
      "id": "rec_m3k9x2_1",            // 'rec_' + base36 creation ms + '_' + per-doc counter
      "label": "House Rent",
      "matchText": "LANDLORD NAME",     // counterparty text used for capture matching; defaults to label
      "amountPaise": 1500000,           // int, > 0
      "dir": "debit",                   // "debit" | "credit" (credit = recurring income, e.g. salary expectation)
      "category": "Rent",
      "bucket": "needs",                // "needs" | "wants" | "savings"
      "mode": "Bank Transfer",          // paymentModes from settings.dart; "Cash" drives policy default
      "accountLast4": "2482",           // optional, nullable; used in matching when set
      "note": null,
      "interval": {
        "type": "monthly",              // "daily" | "weekly" | "monthly" | "customDays"
        "every": 1,                     // int >= 1 (every N days/weeks/months)
        "weekday": null,                // weekly only: 1=Mon..7=Sun
        "dayOfMonth": 5                 // monthly only: 1..31, clamped to month length at firing
      },
      "startDate": "2026-11-05",        // yyyy-mm-dd, first possible due date
      "endDate": null,                  // nullable yyyy-mm-dd; occurrence > endDate never fires
      "maxCount": null,                 // nullable int; occurrence count cap (endDate and maxCount: first hit wins)
      "status": "active",               // "active" | "paused" | "ended"
      "capturePolicy": "matchOrPost",   // "auto" | "matchOrPost" (see §3.3)
      "graceDays": 3,                   // matchOrPost window after due date
      "createdAt": 1794000000000,
      "updatedAt": 1794000000000,
      "occurrences": [                  // newest last; pruned to last 24 per rule (§3.5)
        {
          "date": "2026-11-05",         // due date, yyyy-mm-dd (local)
          "state": "posted",            // pending|posted|matched|skipped|flagged
          "entryId": "…",               // manual-store id when state=posted/flagged
          "captureKey": null,           // dedupeKey when state=matched
          "resolvedAt": 1794000000000
        }
      ]
    }
  ]
}
```

Invariants: dates are **local calendar dates** (`yyyy-mm-dd` strings), never
timestamps — a 05:30 IST phone must not shift a due date. `amountPaise` is the
only amount. Unknown keys on read are ignored; missing optional keys default
as in the current manual-entry decoders (defensive decode, never throw).

### 2.2 Changed document: `manual_store` (additive keys on generated entries only)

Generated entries are written through `manualToJson` extensions:

| Key | Value | Notes |
|---|---|---|
| `amountPaise` | int | Authoritative amount where present |
| `origin` | `"recurring"` | Absent on human entries |
| `recurringId` | rule id | |
| `occurrenceDate` | `yyyy-mm-dd` | The due date (entry `ts` = due date at 12:00 local, so ordering vs same-day captures is stable and the entry is never future-dated by catch-up) |
| `editedByUser` | `true` once the user edits any field post-generation | Written by the existing edit path when `origin == "recurring"`; gates auto-delete in reconciliation (§3.4) |

The entry's rawBody (hence id) is deterministic:
`Recurring <ruleId>|<occurrenceDate>|<dir>|<label>` via a new
`recurringRawBody(...)` beside `manualRawBody` in `app/lib/manual.dart`.

Loader change (single point): wherever a manual entry's amount is read for
totals, use `entry['amountPaise'] ?? paiseFromRupees(entry['amount'])`.

### 2.3 New document: `alert_state_store` (default `{}`)

```jsonc
{
  "2026-11": {                          // budget-month key, §4.2
    "cat:Groceries":  { "80": 1794000000000, "100": null },
    "cat:Travel":     { "80": 1794100000000, "100": 1794200000000 },
    "__overall__":    { "80": null, "100": null }
  },
  "_meta": { "lastNotifiedAt": 1794200000000, "notifiedDates": ["2026-11-07"] }
}
```

Values are fire timestamps (ms) or null. Months older than the previous
budget month are pruned on write. **Not backed up** (derived state, see brief).

### 2.4 Settings document additions (`settings_store`, via `app/lib/settings.dart`)

| Field | Type | Default | Purpose |
|---|---|---|---|
| `overallMonthlyCapPaise` | int? | null | Feature B overall cap; null = overall alerts off |
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
  tap → rule detail (edit, pause/resume, end, delete, occurrence history),
  **"+"** → create form: label, amount (₹ input → paise), direction,
  category/bucket (existing pickers), mode, account last4 (optional),
  interval picker, start date, optional end (date or count), capture policy
  (pre-selected by mode, changeable), grace days (advanced, default 3).
- **Create-from-entry:** long-press any transaction → "Repeat this" pre-fills
  the form (amount, label as matchText seed, category, mode).
- Deleting a rule never deletes posted entries; ending keeps history visible.

### 3.2 Schedule computation (pure Dart, `app/lib/recurring.dart`)
`List<String> dueDates(Rule r, String fromExclusive, String toInclusive)` —
pure function over date strings, unit-testable without the store.
- daily: every N days from startDate.
- weekly: every N weeks on `weekday` (first fire = first such weekday ≥ startDate).
- monthly: every N months on `min(dayOfMonth, lastDayOfMonth)` — clamp per month,
  computed from the *nominal* day each time (31 → Feb 28/29 → Mar 31; no drift).
- customDays: alias of daily with N > 1 presented as "Every N days".
- Stop conditions: date > endDate, or count of fired occurrences ≥ maxCount
  → rule auto-transitions to `ended` when the last allowed occurrence resolves.

### 3.3 Generation & reconciliation pass
Runs as one idempotent pass, `RecurringEngine.run(now)` in
`app/lib/recurring.dart`, invoked from the Shell after `loadTransactions()`
completes: on cold start, on resume, and after any manual add/edit.
Order inside the pass (per active rule, oldest due date first):

1. **Resolve pending occurrences** (state `pending`, due date within
   `[date − 3d, date + graceDays]`): search captured transactions for a match:
   `paiseFromRupees(capture.amount) == rule.amountPaise` **and** direction equal
   **and** (rule.accountLast4 == null || capture.accountLast4 == rule.accountLast4)
   **and** counterparty contains matchText (case-insensitive; skipped if the
   capture has no counterparty) **and** capture date within the window.
   First match wins → occurrence `matched`, record `captureKey`. A capture may
   satisfy **only one** occurrence across all rules (consumed-keys set built
   during the pass; ties broken by earliest due date).
2. **Expire pending occurrences** past `due + graceDays` with no match → post
   the entry (§2.2), occurrence `posted`.
3. **Create occurrences for due dates ≤ today** not yet recorded:
   - policy `auto` → post entry immediately, occurrence `posted`.
   - policy `matchOrPost` → occurrence `pending`, then step 1 logic applies
     (a capture may already exist — e.g. paid early).
4. **Late-match sweep:** for occurrences `posted` within the last 35 days,
   if a capture now matches (same test as step 1, window widened to the
   capture's own date ±3d around the due date) and the entry is untouched
   (`editedByUser` absent) → remove the generated entry from `manual_store`,
   occurrence → `matched`. If the entry **was** edited → occurrence →
   `flagged`, and the Recurring screen shows a "Possible duplicate" row the
   user resolves with one tap (Keep both / Remove generated). Never auto-delete
   user-edited data.
5. **Catch-up bounds:** due dates older than **today − 90 days** are recorded
   as `skipped` without posting **[Guna-pending: window]**. Occurrences that
   fell during `paused` are recorded `skipped` when the rule is next processed
   **[Guna-pending: pause semantics]**.
6. Persist `recurring_store` once at pass end (single commit write). The pass
   is deterministic-id safe (§2.2): before posting, check `manual_store` for
   the deterministic entry id; if present, record `posted` and do not re-add —
   a crash between entry-write and store-write heals on the next pass.

### 3.4 Interaction with the rest of the app
- Generated entries appear in Transactions with a small "↻ Recurring" tag
  (they are ordinary manual-store entries otherwise: they count in Home,
  Insights, budgets, exports, splits exclusion — splits unaffected).
- Budgets: generated entries count exactly like manual entries (they're real
  spend). Salary-type credit rules count as income.
- **Reversal handling:** a captured refund/credit is never auto-linked to an
  occurrence (documented limitation). If a *matched* capture is later removed
  by the user via the existing removed-store flow, the occurrence stays
  `matched` — the rule does not re-post (prevents resurrection loops).

### 3.5 Edge cases (explicit)
- Amount edited on a rule → future occurrences use the new amount; a `pending`
  occurrence already waiting keeps the amount it was created with (snapshot
  `amountPaise` onto the occurrence at creation — add field
  `amountPaise` per occurrence; matching uses the snapshot).
- Rule deleted with a `pending` occurrence → pending is discarded silently.
- Clock/timezone travel: all logic on local date strings; a date-line crossing
  can at worst delay a posting by a day, never duplicate (deterministic ids).
- Two rules, same amount + same counterparty (e.g. two SIPs, same fund house):
  consumed-keys + earliest-due-first makes assignment deterministic; the
  second rule falls back to posting after grace. Acceptable, documented.
- SMS store is capped (rolling 500): a matched capture's SMS may age out and
  the capture vanish from `loadTransactions()`. The occurrence record is the
  source of truth — nothing re-posts. ✔ by design (§3.3 step 4 only sweeps
  `posted` occurrences younger than 35 days, and only *toward* matched).

---

## 4. Feature B — Budget alerts (80% / 100%)

### 4.1 Evaluation
`BudgetAlerts.evaluate(...)` in new `app/lib/budget_alerts.dart`, called:
after `loadTransactions()` + recurring pass, after manual add/edit/delete,
after any budget cap edit, after `overallMonthlyCapPaise` changes.
Inputs: per-category spent (paise, current budget month), caps (paise,
converted at read), overall spent/cap.
For each category with cap > 0 (and for `__overall__` if a cap is set):
`pct = spent * 100 ~/ cap` (integer math only). For thresholds 100 then 80:
if `pct >= t` and state[t] is null → **fire**: record timestamp, queue for
notification. If `pct < t` and state[t] is set and the drop is due to a *cap
increase* (cap value changed since last evaluation — track last-seen cap in
state as `capPaise`) → clear state[t] (re-arm). Spend decreases alone (entry
deleted) do **not** re-arm within the month — prevents delete-and-respend
notification loops.

### 4.2 Budget month
Month key = the app's existing budget-month bucketing driven by
`monthStartDay` in settings (same function the Budgets screen uses — reuse,
do not re-implement). Key format `yyyy-mm` of the bucket's *start* date.

### 4.3 Notification rules (anti-spam, normative)
1. At most **one** notification per evaluation; it aggregates all crossings:
   title "Budget alert", body lists up to 3: "Groceries crossed 100%",
   "Travel crossed 80%" (+ "+2 more"). In-app banner on Home + Budgets lists all.
2. At most **2** budget-alert notifications per calendar day (`_meta.notifiedDates`).
   Further crossings still record state and show in-app, silently.
3. No notification when `budgetAlertsOn == false` (state still records → no
   burst when re-enabled).
4. Channel `kanakku_budget_alerts`, IMPORTANCE_DEFAULT. Content visibility
   SECRET: lock screen shows "Budget alert — open Kanakku"; amounts appear
   only as percentages, never balances (audit F12 pattern).
5. Notification permission: reuse existing `requestNotificationPermission`
   flow; if denied, in-app only, no repeated asks.

### 4.4 UI
- Budgets screen: rows already show % used; add threshold ticks at 80% on the
  progress bar and a fired-state dot. Settings → "Budget alerts" toggle +
  "Overall monthly budget" field (₹ → paise) + note that alerts are checked
  when the app opens.
- Home: dismissible banner when any unfired-in-app crossing happened today.

---

## 5. Feature C — Biometric unlock

### 5.1 Dependency verdict (blocker, resolved by design)
`local_auth` is absent and cannot be added (offline build, zero-plugin
pubspec). Design uses **framework** APIs only:
- `android.hardware.biometrics.BiometricPrompt` (API 28+) — primary.
- `KeyguardManager.createConfirmDeviceCredentialIntent` (API 21+) — fallback
  for API < 28 / no enrolled biometric.
- Manifest: add `<uses-permission android:name="android.permission.USE_BIOMETRIC"/>`
  (normal permission). No Gradle changes (framework classes only; MainActivity
  passes `ContextCompat`-free executor via `mainExecutor` on API 28+…
  implementation detail: `context.mainExecutor`).

### 5.2 Capability probe — channel `biometricStatus` → exactly one of:
`available` (hardware + enrolled + device secure) · `noneEnrolled` ·
`noHardware` · `noDeviceLock` · `unsupportedApi` (API < 28 → device-credential
path may still make the toggle offerable as "Use device lock"; v1.1 behaviour:
on `unsupportedApi` the toggle is shown as **unavailable** with explanation —
device-credential-as-unlock is a v1.2 decision) **[Guna-pending]**.
Probe uses `BiometricManager.from(ctx).canAuthenticate(BIOMETRIC_STRONG)`
where available (framework API 29+); on API 28 falls back to
`FingerprintManager.hasEnrolledFingerprints()` (deprecated, functional).

### 5.3 Prompt flow — channel `biometricPrompt`
Native builds `BiometricPrompt` with title "Unlock Kanakku", subtitle
"Use fingerprint or face", negative button "Use PIN". Callbacks map to:
success → `true`; ERROR_USER_CANCELED / negative → `false` + Dart shows PIN
pad; ERROR_LOCKOUT / ERROR_LOCKOUT_PERMANENT → `false` + PIN pad (system
enforces its own biometric lockout); any other error → `false` (fail-closed).

### 5.4 Gate integration (`_AppGateState`, `_LockScreen` in `main.dart`)
- When the gate locks and `biometricUnlock && pinSet && status == available`:
  show the biometric prompt automatically once; PIN pad is visible beneath/
  behind with an explicit "Use PIN" affordance and a "Try biometrics again"
  icon button. PIN entry path is byte-for-byte the existing one (counted
  verify + lockouts untouched).
- **Lockout interplay [Guna-pending]:** biometric success unlocks even while a
  PIN lockout timer is running (recommended); biometric failure never touches
  the PIN failure counters.
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

### 5.5 Security notes
- Biometric here is a **convenience verifier for the privacy lock**, exactly
  as strong as the threat model allows: the at-rest data key is a device
  Keystore key not bound to user authentication, and the PIN likewise
  encrypts nothing (audit F3/F7 context) — v1.1 does not change that model
  and the Settings copy must say "App lock keeps casual viewers out".
- Prompt-only auth cannot detect new-fingerprint enrollment (no
  auth-bound Keystore key); documented limitation from the brief.
- No biometric data or templates are ever accessible to the app — the system
  prompt returns only success/failure. Nothing biometric is stored, logged,
  or backed up; the backed-up `biometricUnlock` flag is inert on a new
  device until the probe passes and the user re-enables via PIN.

---

## 6. Migration plan (v1.0.4 → v1.1) — following the `migrated_v104` precedent

Native flag `KEY_MIGRATED_V110 = "migrated_v110"` in CaptureStore prefs.
On first v1.1 launch (Dart init, before the Shell loads), idempotent steps:

1. If `recurring_store` doc absent → write `{"rules":[]}`. Same for
   `alert_state_store` → `{}`.
2. Settings doc: no rewrite (new fields default at decode).
3. Budgets doc: no rewrite (conversion at read).
4. `manual_store`: **no rewrite** — generated-entry keys are additive and
   written only for new entries; legacy entries load via existing defaults.
5. Set `migrated_v110`. Re-running the whole sequence is a no-op (safe after
   a crash mid-migration; there is no destructive step to resume).

**No existing transaction is touched, re-keyed, or re-written by migration.**
Rollback: v1.0.4 ignores the two new documents and the additive manual keys;
the only loss on downgrade is the rules themselves and the biometric flag.

Backup/restore: `backupStoreKeys` += `'recurring'`. Restoring a v1.1 backup
into v1.1 restores rules (occurrences included, so nothing re-fires);
restoring a v1.0.4 backup leaves any existing rules intact only if the
restore flow's per-key write is skipped for absent keys — **verify against
`parseBackup` behaviour and specify: absent key in backup = leave current
store untouched** (this must be tested, §7 T-B3).

---

## 7. Test checklist (for Goldfish attack + implementation QA)

**Money & rounding**
- T-M1: ₹499.99 rule → 49999 paise everywhere; totals equal capture-side
  `499.99` double conversion exactly (no 49998/50000 drift).
- T-M2: cap ₹3,000.00 stored as double `3000.0` → 300000 paise; 80% fires at
  spent 240000, not 239999.
- T-M3: integer pct math: spent 1 paise over 80% of an odd cap (e.g. ₹333.33)
  fires; 1 paise under does not.

**Recurring engine**
- T-R1: monthly day-31 rule: Jan 31 → Feb 28 (2027) / Feb 29 (2028) → Mar 31 (no drift).
- T-R2: weekly every-2-weeks across a month boundary; customDays N=10 across DST-free IST (no DST in India — verify no UTC conversion sneaks in).
- T-R3: app unopened 45 days, monthly rent rule → exactly 1 catch-up entry (plus current), each with correct occurrence `ts` (noon of due date).
- T-R4: catch-up > 90 days → older occurrences `skipped`, one in-app notice, no entries.
- T-R5: run the pass twice back-to-back, and kill the app mid-pass → zero duplicate entries (deterministic ids).
- T-R6: `matchOrPost`: matching UPI capture on due date → occurrence `matched`, no entry; budget totals count the spend once.
- T-R7: no capture within grace → entry posts on day grace+1, dated at due date.
- T-R8: capture arrives 10 days after fallback posting → generated entry removed, occurrence `matched`, totals unchanged (counted once throughout).
- T-R9: same as T-R8 but user edited the generated entry's category → entry kept, occurrence `flagged`, duplicate-resolution row appears; both resolution choices verified.
- T-R10: two rules, identical amount + counterparty, overlapping windows → deterministic assignment (earliest due consumes the capture); second rule posts after grace.
- T-R11: paused rule across 2 due dates → both `skipped`, nothing posts on resume.
- T-R12: rule amount edited while an occurrence is `pending` → matching uses the snapshotted amount.
- T-R13: matched capture deleted by user → no re-post, ever.
- T-R14: credit rule (salary) with `matchOrPost` matches a salary credit capture; budgets/income totals count once.
- T-R15: maxCount=3 rule fires exactly 3 times then auto-`ended`.

**Budget alerts**
- T-B1: crossing 80 then 100 in separate evaluations → one notification each; repeated evaluations at same spend → zero repeats.
- T-B2: one evaluation crossing 3 categories → exactly 1 aggregated notification.
- T-B3: restore of a v1.0.4 backup → rules preserved-or-cleared per §6 spec; alert state re-evaluates fresh, no burst of >1 notification.
- T-B4: cap raised mid-month dropping pct below 80 → flag re-arms; re-crossing fires again (once).
- T-B5: entry deleted dropping pct → no re-arm; re-spend past threshold → no second notification this month.
- T-B6: `monthStartDay = 25`: crossing on the 24th belongs to the previous budget month; state does not reset on the 1st.
- T-B7: 3rd crossing in a day → state recorded, banner shows, no 3rd notification.
- T-B8: overall cap unset → no overall alert even if total spend is huge; set → fires at 80/100 of overall spent (all categories incl. uncapped).
- T-B9: alerts off → crossings recorded silently; re-enable → no catch-up burst.
- T-B10: lock screen shows redacted public text only (no amounts).

**Biometric unlock**
- T-C1: API 35 + enrolled fingerprint: cold start → prompt → success unlocks; cancel → PIN pad; wrong PINs still lock out per existing schedule.
- T-C2: API 27 device (or emulator): toggle shows unavailable + reason; PIN flow untouched.
- T-C3: no enrolled biometrics / no device lock → probe states surface exact copy; toggle cannot enable.
- T-C4: enable flow: wrong PIN at the enable gate → counted failure (lockout machinery), toggle stays off.
- T-C5: PIN lockout active → biometric success unlocks [if Guna approves]; PIN pad still enforces remaining lockout for PIN attempts.
- T-C6: PIN disabled in Settings → `biometricUnlock` forced false; re-setting a PIN does not silently re-enable biometrics.
- T-C7: channel forced to throw/timeout → PIN pad appears (fail-closed), app never opens unlocked.
- T-C8: system biometric lockout (5 bad fingers) → prompt error routes to PIN pad.
- T-C9: backup restored on a second device → flag present but gate uses PIN until re-enabled via PIN + probe.

**Migration & compatibility**
- T-X1: real v1.0.4 stores (all document types populated) → v1.1 first launch: every transaction, budget and setting intact; migration runs once; second launch no-op.
- T-X2: v1.1 backup → v1.0.4 app restore: no crash, ledger intact, rules absent.
- T-X3: `wipeAll` clears recurring + alert state + biometric flag with everything else.
- T-X4: offline build passes with **zero** changes to `pubspec.yaml` and Gradle dependency blocks; manifest diff = `USE_BIOMETRIC` only.

---

## 8. Exact files to change (implementation map)

**New:** `app/lib/money.dart` · `app/lib/recurring.dart` ·
`app/lib/budget_alerts.dart` ·
`app/android/.../BudgetNotifier.kt`
**Dart edits:** `app/lib/capture.dart` (channel methods §2.5) ·
`app/lib/manual.dart` (`recurringRawBody`, `amountPaise`/`origin` write+read) ·
`app/lib/budgets.dart` (paise conversion at read) ·
`app/lib/settings.dart` (§2.4 fields) · `app/lib/backup.dart`
(`backupStoreKeys` += `'recurring'`) · `app/lib/main.dart` (Recurring screen,
gate biometric branch, evaluation hooks — insert at `_AppGateState`,
`_LockScreen`, Shell load completion, Budgets screen).
**Kotlin edits:** `CaptureStore.kt` (2 keys + accessors + clearAll) ·
`MainActivity.kt` (channel handlers §2.5, biometric probe/prompt) ·
`AndroidManifest.xml` (`USE_BIOMETRIC`).
**Untouched:** `parser/` (no parser changes needed), `PinStore.kt`,
`StoreCrypto.kt`, `BackupCrypto.kt`, `pubspec.yaml`, Gradle files.

## 9. Out of scope for v1.1 (explicit)
Custom alert thresholds · biometric for balance-reveal/Settings prompts ·
refund-to-rule auto-linking · auth-bound Keystore data key · native
background evaluation · Drift/SQLite migration · iOS.
