# Kanakku v1.1 — Concepts Brief (EGM Phase 1: Elephant Brainstorm)

**Features:** A. Recurring transactions · B. Budget alerts (80%/100%) · C. Biometric unlock
**Status:** brainstorm only — no code. Decisions marked **[Guna]** need the human approver.
**Companion:** `design_draft.md` (Phase 2 draft built on the recommendations below).

---

## 0. Ground truth the brainstorm had to respect

These are facts of the current codebase (v1.0.4 / app 1.1.4), not assumptions:

1. **There is no database.** All state is JSON documents in the native `CaptureStore`
   (SharedPreferences), encrypted at rest since v1.0.4 via `StoreCrypto` (Keystore
   AES-256-GCM). New features = new documents + new channel methods, following the
   existing pattern — *not* new tables. The spec's Drift/SQLite plan was never built.
2. **Money in Dart is `double` rupees today** (parser, manual entries, budgets).
   The v1.1 invariant "integer paise, never floats" therefore cannot be assumed —
   it must be *introduced*: all new v1.1 stores are paise-native, with one audited
   conversion boundary for legacy doubles. Pretending the old data is paise would
   be the fastest route to silent rounding bugs.
3. **Captured transactions are derived, not stored.** SMS/notification entries are
   re-parsed on every load and deduped by `dedupeKey = amount(2dp)|accountLast4|upiRef`.
   Manual entries live in a separate store and are never deduped against captures.
   This split is the root of Feature A's hardest problem (double-counting).
4. **`pubspec.yaml` has zero plugins** (Flutter SDK + cupertino_icons + first-party
   parser only), and the offline build cannot add any. So: no `local_auth`,
   no `flutter_local_notifications`, no WorkManager. Everything in v1.1 must be
   built on the existing method channel (`in.kanakku/capture`), the framework
   Android APIs, and the existing native patterns (PinStore, SummaryNotifier's
   AlarmManager + Notification.Builder).
5. **The PIN lock is already hardened** (v1.0.4 fixed audit F1/F7: PBKDF2 verifier,
   native counted failures, 30 s→15 min lockouts, reset hatch removed). Feature C
   adds a second verifier beside it; it must not re-open F1.
6. **Nothing runs in the background in Dart.** The only native background piece is
   the daily-summary alarm, which posts *text Dart computed earlier*. Any
   "real-time" behaviour for A or B is impossible without new native logic;
   the honest model is *evaluate on app open / resume / data change*.

---

## Feature A — Recurring transactions

### The core tension
A recurring rule (rent, SIP, subscription) wants to *create* entries. But for most
real payments a bank SMS/notification **also** arrives and creates a captured entry.
Naively auto-posting = every rent payment counted twice. This is the exact
duplicate/reversal problem the EGM review lenses call out.

### Options considered

**A1. Always auto-post (dumb scheduler).**
Rule fires → manual entry appears. User manually deletes the SMS duplicate.
- ➕ Dead simple, predictable, works for cash payments (no SMS ever comes).
- ➖ Double-counts the majority case (UPI/bank payments), corrupts budgets and
  the month donut — the app's core promise is "your numbers are right".

**A2. Never post — rules are reminders only.**
Rule shows "Rent due today"; user confirms or the SMS does it.
- ➕ Zero double-count risk.
- ➖ Not really "recurring transactions"; cash rent (a primary Indian use case)
  never lands in the ledger without manual work. Fails the feature request.

**A3. Expectation + reconciliation (recommended).**
Rule creates an *occurrence* on each due date. What happens next depends on the
rule's `capturePolicy`:
- `auto` (default for Cash mode): post the entry immediately — no capture will come.
- `matchOrPost` (default for UPI/Card/Bank Transfer): wait a grace window
  (default 3 days) for a matching captured transaction (same paise amount,
  account last4 if set, counterparty fuzzy-match on the rule's match text,
  within ±3 days of the due date). If a capture matches → occurrence is *matched*,
  no entry is posted (the capture IS the entry). If the window closes with no
  match → post the entry (marked as recurring-generated).
- Late-match cleanup: a capture can arrive *after* the fallback entry posted
  (SMS delayed, statement imported later). The next reconciliation pass detects
  the pair and removes the **generated** entry — but only if the user has not
  edited it since posting; if edited, it flags an in-app "possible duplicate"
  instead of deleting the user's data.
- ➕ Correct totals in both worlds; deterministic, testable, self-healing.
- ➖ Most complex option; matching quality depends on counterparty text, and
  `dedupeKey` has no date/counterparty component, so two identical-amount SIPs
  to the same account are genuinely ambiguous (mitigated by date window +
  match text, not eliminated).

**A4. Post, and suppress the capture.**
Generated entry posts; matching captures are hidden via the removed-store.
- ➖ Fights the derived-capture architecture: captures are re-parsed every load,
  suppression lists become permanent bookkeeping, and deleting the rule later
  resurrects hidden captures. Rejected.

**Recommendation: A3**, with `capturePolicy` per rule and a sensible default by
payment mode.

### Sub-decisions

- **Catch-up after the app is unopened for weeks:** post *all* missed occurrences
  (rent really was paid each month) vs only the latest vs ask each time.
  Recommended: post all missed up to **90 days** back; older occurrences are
  marked `skipped` and surfaced once in-app. **[Guna: confirm 90-day default]**
- **Pause semantics:** occurrences falling inside a pause are *skipped, never
  caught up* (recommended — pausing a subscription usually means it stopped),
  vs caught up on resume. **[Guna]**
- **Edit semantics:** editing a rule changes future occurrences only; posted
  entries are history and never rewritten (same rule as bank ledgers).
- **Month-end:** day 31 clamps to the month's last day (31 Jan → 28/29 Feb → 31 Mar),
  it does not drift to the 28th permanently. Standard, but must be explicit for Goldfish.
- **Reversals/refunds:** if a payment is refunded, the refund arrives as its own
  captured credit — v1.1 does **not** auto-link it to the occurrence (documented
  limitation; auto-linking refunds to rules is a v1.2 candidate). **[Guna: aware]**
- **Deterministic entry ids:** generated entries reuse the manual-store id scheme
  (hash of rawBody) with rawBody = `Recurring <ruleId>|<yyyy-mm-dd>|<dir>|<label>`,
  making the generation pass idempotent and crash-safe — running it twice, or
  dying halfway, can never double-post.

---

## Feature B — Budget alerts at 80% and 100%

### Options considered

**B1. Evaluate on app open only, notify in-app only.**
- ➕ Zero native work, zero spam risk.
- ➖ The user learns about the breach when they next open the app — which is
  also when they'd see the Budgets screen anyway. Weak.

**B2. Evaluate on open/resume/data-change; notify via native notification +
in-app banner (recommended).**
Reuses the SummaryNotifier pattern (framework `Notification.Builder`, its own
channel). Crossings are computed in Dart whenever fresh totals exist.
- ➕ Real alerts, no new dependencies, honest about timing.
- ➖ A crossing caused by an SMS that arrives while the app stays closed is
  only detected at next open. This is inherent to the architecture (§0.6) and
  must be stated to the user, not hidden.

**B3. Native-side evaluation on every captured SMS.**
Native would have to re-implement budget math + parsing in Kotlin.
- ➖ Duplicates the entire Dart budget engine; double maintenance forever. Rejected.

**Recommendation: B2.**

### Anti-spam design (the real feature)
- **Fire once** per threshold (80, 100) per category per budget month. State is
  persisted (`alert_state_store`), so restarts don't re-fire.
- **Coalescing:** one evaluation that crosses 3 budgets produces **one**
  notification ("3 budgets need attention"), never three. Hard cap: at most
  2 budget-alert notifications per day.
- **Cap edits reset state honestly:** if the user raises a cap and the category
  drops below a fired threshold, that threshold's fired-flag clears (a later
  re-crossing may fire again — this is correct, not spam).
- **Month rollover:** state is keyed by the app's budget month, which honours
  the existing `monthStartDay` setting — a salary-cycle month (e.g. starts on
  the 25th) must not reset alerts on the 1st.
- **Lock-screen hygiene:** following audit F12's lesson, the notification's
  public version is redacted ("Budget alert — open Kanakku"); amounts/% live
  in the private version only.
- **Overall monthly budget:** per-category alerts exist today (caps are
  per-category). An *overall* alert needs an overall cap, which does not exist
  yet. Options: (i) explicit overall cap setting (paise-native, in settings);
  (ii) derive overall = sum of category caps — misleading when some categories
  are uncapped. Recommended: (i), alerts off until the user sets it. **[Guna]**
- **Thresholds fixed at 80/100** per spec §2.6; custom thresholds are out of
  scope for v1.1 (settings creep).

---

## Feature C — Biometric unlock

### ⛔ BLOCKER (flagged, with workaround)
`local_auth` is **not** in `pubspec.yaml` and **cannot be added** (offline build,
no new pub dependencies — hard constraint). Any design that assumes `local_auth`
is dead on arrival.

### Options considered

**C1. Framework `android.hardware.biometrics.BiometricPrompt` (API 28+) over the
existing method channel (recommended).**
Framework API — no Gradle dependency, no pub dependency. Works from the existing
MainActivity. API 28 covers the overwhelming majority of devices in the field.
- ➕ Zero new dependencies; system UI; hardware-backed.
- ➖ API 24–27 devices (minSdk is Flutter's, currently 24) get no biometric —
  they fall back to device credential or PIN (see C2). Framework prompt is
  less configurable than the AndroidX one (e.g. no built-in "use PIN" button
  on all API levels — we supply our own negative button → PIN pad).
- Note: needs `USE_BIOMETRIC` in the manifest (normal permission, no runtime ask).

**C2. Device credential only (`KeyguardManager.createConfirmDeviceCredentialIntent`).**
Works API 21+, zero dependencies.
- ➕ Maximum compatibility; this is also the audit F1 suggested gate for resets.
- ➖ It's the phone's unlock (PIN/pattern/password), not biometrics per se;
  users asked for fingerprint. Kept as the fallback layer inside C1 for
  API < 28 or no enrolled biometrics.

**C3. Wait until dependencies are possible.**
- ➖ Blocks a headline trust feature indefinitely for a packaging problem. Rejected.

**Recommendation: C1 with C2 fallback**, capability-probed at runtime:
`available | noHardware | noneEnrolled | noDeviceLock | unsupportedApi`.

### Security posture (must not weaken the v1.0.4 baseline)
- **Biometric is a verifier beside the PIN, not a replacement root.** The PIN
  stays mandatory: the toggle can't be enabled until a PIN exists; disabling
  the PIN disables biometrics; "Use PIN" is always one tap away.
- **Enable/disable requires a counted PIN verification** (goes through
  `PinStore.verifyCounted`, so the F1 lockout machinery applies).
- **Enrollment-change blindness — documented limitation:** without a
  Keystore key bound to biometric auth (`setUserAuthenticationRequired`),
  Android cannot tell us a *new* fingerprint was enrolled. v1.1 uses prompt-only
  auth, so a newly enrolled fingerprint on the device also unlocks Kanakku.
  This matches the existing trust model — the PIN encrypts nothing either;
  the data key is a device-Keystore key, not user-auth-bound (audit F3/F7
  context). Binding the data key to user auth is a bigger redesign, **out of
  scope**, flagged so Guna chooses knowingly. **[Guna: aware]**
- **Lockout interplay:** if PIN attempts have tripped a lockout, can biometrics
  still unlock? Android's own behaviour says yes (different factor). Recommended:
  **yes** — biometrics remain available during PIN lockout; the lockout exists
  to stop PIN guessing, and a fingerprint is not a guess. **[Guna: confirm]**
- **Timeout behaviour:** unchanged from today — the gate locks on cold start
  and on resume after the existing background threshold; biometrics are offered
  exactly when the PIN pad would be. No new timeout setting in v1.1.
- **Scope:** app gate only. The separate PIN prompts for balance reveal and
  Settings changes keep using PIN in v1.1 (biometric there = v1.2 candidate).
- **Fail-closed:** any channel error/timeout in the biometric path falls back
  to the PIN pad — never to an unlocked app (contrast audit F13's history:
  v1.0.4 already made the gate fail-closed; C must preserve that).

---

## Cross-cutting decisions

- **Paise strategy:** new stores (`recurring_store`, alert state, overall cap)
  are integer-paise only. Legacy doubles convert at exactly one boundary
  (`(rupees * 100).round()`). Generated manual entries carry both `amount`
  (double, so old app versions and existing code keep working) and
  `amountPaise` (int, authoritative where present). **[Guna: aware — this is
  the only safe way to honour "never floats" without a flag-day rewrite]**
- **Backups:** `recurring_store` joins the backup (rules are user data);
  alert state does **not** (derived state — restoring stale "already fired"
  flags could silently suppress alerts on a new phone; it re-evaluates fresh).
  Backups stay v2-passphrase format, format version unchanged (store keys are
  additive inside the existing envelope).
- **Downgrade safety:** a v1.1 backup restored into v1.0.4 loses the rules
  (old code ignores unknown store keys) but corrupts nothing; v1.1 reading
  v1.0.4 data is the supported direction and is fully specified in the draft.
- **No background guarantees:** A and B act on app open/resume. The daily
  summary already works on a "computed when open, posted by alarm" model, so
  user expectations are consistent. **[Guna: confirm acceptable]**

## Open questions for Guna (approver)

1. Catch-up window: 90 days all-missed (recommended) vs latest-only?
2. Pause = skip occurrences during pause (recommended) vs catch up on resume?
3. Overall budget: add an explicit overall monthly cap setting (recommended),
   or per-category alerts only in v1.1?
4. Biometrics allowed during a PIN lockout (recommended yes)?
5. App-open-only evaluation for alerts/recurring is acceptable for v1.1?
6. Aware & accepted: biometric prompt-only (new device fingerprint also
   unlocks), documented in §C — proceed?
7. Default grace window for `matchOrPost`: 3 days — right for salary/Rent
   timing quirks, or 5?
