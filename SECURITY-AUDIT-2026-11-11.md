# Kanakku — Security Audit #2 (hacker point of view, read-only)

**Date:** 2026-11-11 · **Scope:** `~/workspace/kanakku-project` @ app **v1.1.5+2015** (pubspec.yaml) — Flutter/Dart (`app/lib`), parser package (`parser/lib`), Kotlin native layer (`app/android`), plus the shipped release APK (`~/workspace/your_files/kanakku/kanakku-v1.1-arm64.apk`, signature inspected). **Method:** manual code review + targeted grep + APK certificate verification. No files were modified. No dynamic/on-device testing.

**Baseline:** every finding of the 2026-10-29 audit (F1–F16, app v1.1.3) was re-checked against the current code first; new issues found this pass are labelled **N1–N9**.

**Headline:** this codebase has been *seriously* hardened since v1.1.3. Both Highs and all four Mediums from the first audit are fixed in code, and the fixes were verified in the shipped artifact where that matters (the v1.1.5 APK is signed with the real `CN=Kanakku Upload` key — checked with `apksigner`). What remains is a tail of Low-severity residuals and policy weaknesses. **An attacker cannot read the ledger from extracted files, cannot brute-force the PIN online at any useful speed, and cannot ride a debug-signed fake update. The realistic remaining attacks need prolonged physical access to the unlocked phone, or social engineering around file sharing.**

**Open-item count: 0 Critical · 0 High · 0 Medium · 7 Low · 3 Info.**

---

## Part 1 — Status of the 2026-10-29 findings

### F1 — HIGH — App-lock bypass via "Reset lock" + no throttling → ✅ FIXED (residual: N1)

- The Reset-lock hatch is **gone**: `app/lib/pin.dart` L3–9 documents its removal; the only `pinClear()` call site (`app/lib/main.dart` L5551) sits inside Settings → Disable, *after* a successful counted verify (L5542).
- Attempts are now counted **natively and persistently**: `PinStore.kt` `verifyCounted()` — 5 failures → lockout of 30 s, doubling per lockout, capped at 15 min (`MAX_FAILURES`, `lockoutSeconds()`, counters in prefs, so killing the app does not reset them).
- **All five** PIN prompts funnel through the one counted channel method `pinVerify`: lock screen (`main.dart` L341), balance reveal (L2353), change PIN (L5521), disable PIN (L5542), biometric toggle (L5572). No uncounted verify is exposed over the channel.

### F2 — HIGH — Every SMS archived verbatim incl. OTPs → ✅ MOSTLY FIXED (residual: N2)

- `SmsReceiver.kt` now persists a message **only** when `FinanceFilter.keepSms()` passes (amount pattern **and** finance keyword, or a known bank sender-id). A one-time migration (`CaptureStore.runV104Migrations`, `CaptureStore.kt`) purges the pre-filter archive on upgrade. The archive that remains is encrypted at rest (F3 fix) and excluded from platform backup (F4 fix).
- Residual (bank-sender bypass) is recorded as **N2** below.

### F3 — MEDIUM — Plaintext financial data at rest → ✅ FIXED (residual: N3)

- New `StoreCrypto.kt`: every CaptureStore document (SMS/notification archives, manual, statement, splits, budgets, settings, categories, recurring, alert state) is AES-256-GCM encrypted with a 256-bit key generated in and never leaving the Android Keystore; legacy plaintext values migrate transparently on next write. PIN prefs hold only the PBKDF2 verifier (F7 fix).
- The key is deliberately **not** bound to user authentication so background capture works on a locked phone — file extraction alone now yields ciphertext. Residual silent-fallback issue is **N3**.

### F4 — MEDIUM — Backup/transfer rules undeclared → ✅ MOSTLY FIXED (residual: N4)

- `AndroidManifest.xml`: `android:allowBackup="false"` is now declared, with a comment citing this audit. Cloud backup and `adb backup` egress are closed. Residual D2D nuance is **N4**.

### F5 — MEDIUM — Backup export is one plaintext file with the whole history → ✅ FIXED (option + warning; residual: N5)

- New format v2 envelope (`app/lib/backup.dart` L14–27): the backup is passphrase-encrypted natively by `BackupCrypto.kt` — **PBKDF2-HMAC-SHA256, 120,000 iterations, AES-256-GCM, random 16-byte salt + 12-byte IV, 128-bit tag**. This is textbook-sound, not home-grown: a wrong passphrase fails the GCM tag and decrypt returns null (no oracle, no partial plaintext).
- Restore flow (`main.dart` `_doRestore`, ~L1391): decrypt happens **before** anything is written; a wrong passphrase aborts cleanly. The backup UI (L1248–1257) and the in-app FAQ (L6436) both recommend Encrypt and state plainly that a plain backup "is readable by anyone who gets the file".
- The PIN exclusion claim re-verified: `backupStoreKeys` = manual/removed/splits/budgets/statement/categories/recurring; settings hold no secrets; no channel method returns hash or salt.
- Residual: the **plain v1 format is still offered** as a user choice (warned, not hidden), and the encrypted option's passphrase policy is weak — **N5**.

### F6 — MEDIUM — Release signed with the debug key → ✅ FIXED (verified in the shipped APK; residual: N6)

- `build.gradle.kts` now loads a dedicated release keystore from outside the repo (`~/.kanakku-signing/key.properties`, or `$KANAKKU_KEY_PROPERTIES`).
- **Artifact check:** `apksigner verify --print-certs` on the shipped v1.1.5 APK → `Signer #1 certificate DN: CN=Kanakku Upload, O=Kanakku, L=Chennai, ST=Tamil Nadu, C=IN`, SHA-256 `2521b65c…d552`. Not the Android debug key. The update-integrity hole is closed for the build Guna actually ships.
- Residual build-config footgun is **N6**.

### F7 — MEDIUM — Single-round SHA-256 PIN verifier → ✅ FIXED

- `PinStore.kt`: PBKDF2-HMAC-SHA256, **120,000 iterations**, 16-byte `SecureRandom` salt, 256-bit output; constant-time `MessageDigest.isEqual` retained. Legacy SHA-256 hashes still verify once and are transparently re-hashed to PBKDF2 on first successful verify — no lockout-by-upgrade.

### F8 — LOW — No FLAG_SECURE → ✅ FIXED

- `MainActivity.kt` L38: `window.addFlags(FLAG_SECURE)` unconditionally in `onCreate` — recents thumbnails, screenshots and screen recording are blocked app-wide. (Side effect Guna has already met: he cannot screenshot his own app for store listings. That is this flag working as intended.)

### F9 — LOW — CSV formula injection → ✅ FIXED

- `app/lib/csv_export.dart` `_esc()` (L36–44): any cell starting with `= + - @ \t \r` is prefixed with a single quote before RFC-4180 quoting. Imported-narration payloads can no longer execute in Excel/Sheets.

### F10 — LOW — Statement picker buffers whole file before the cap → ✅ FIXED

- `MainActivity.kt` (~L337–415): read moved to a background thread; the provider's declared size is checked first, then `readCapped()` streams and aborts the moment the stream exceeds 5 MB — memory use is bounded by the cap, not by the file.

### F11 — LOW — Notification capture too broad / fake-transaction injection → ✅ FIXED for notifications (residual: N7)

- `KanakkuNotificationListener.kt`: substring package matching and the shopping/food apps are **gone** — a strict allowlist of 14 exact packages (GPay, PhonePe, Paytm, BHIM, CRED, Mobikwik + 8 bank apps), and the text must additionally pass `FinanceFilter.isFinanceText()`. A lookalike app can no longer inject entries through notifications.
- The SMS side of the injection problem remains by design — **N7**.

### F12 — LOW — Daily summary amounts on the lock screen → ✅ FIXED

- `SummaryNotifier.kt`: notification is `VISIBILITY_PRIVATE` with a neutral public version ("Your daily summary is ready"). `BudgetNotifier.kt` goes further: `VISIBILITY_SECRET`, neutral public version, bodies carry percentages only, never amounts.

### F13 — INFO — App lock fails open on a slow channel → ✅ FIXED

- The gate now fails **closed**: `main.dart` L108–153 — if `pinIsSetStrict()` (capture.dart, deliberately non-swallowing) cannot be answered, the app shows a locked "could not be verified" screen with Retry and `_locked = true`. The biometric prompt is likewise fail-closed (every error/cancel completes `false`, `MainActivity.kt` `biometricPrompt`).

### F14 — INFO — Export files accumulate in cache → ✅ FIXED

- `MainActivity.kt` `exportsDir()` (L451–462) prunes anything older than 24 h on every share; filenames remain app-generated constants (verified at all three Dart call sites, `main.dart` L1141/1162/1373 — no user input reaches the path, no traversal).

### F15 — INFO — Restore validates shape only → ⚠️ STILL OPEN (accepted risk, partially mitigated)

- `parseBackup` (`backup.dart`) validates the envelope, format version, and that every store payload is itself valid JSON (list/map); restore requires an explicit "replaces ALL current data" confirmation; v1.1 adds a restore-in-progress flag so a crash mid-restore can't leave the recurring engine holding half-written rules (`main.dart` `_doRestore`). Payloads are only ever re-parsed by the app's defensive decoders (`decodeSettings`, `decodeSplits`, budgets — all try/catch with defaults), never executed.
- What remains true: a **plain** backup from anyone is unauthenticated — if Guna is talked into restoring someone else's file, he gets their (fabricated) ledger. Data-only impact, user-mediated. The encrypted format *is* authenticated (GCM tag + passphrase knowledge). Accepted for a personal app; no change recommended beyond preferring encrypted backups (N5).

### F16 — INFO — BootReceiver exported → ✅ still correct, not a bug

- Unchanged and still right: `BOOT_COMPLETED` is a system-only protected broadcast; the receiver just re-arms the summary alarm. `SmsReceiver` remains exported behind the signature-level `BROADCAST_SMS` permission. Leave both alone.

---

## Part 2 — New findings in this pass

### N1 — LOW — 4-digit PINs remain brute-forceable by a *patient* attacker with the phone in hand (residual of F1/F7)

- **Evidence:** PIN policy is still 4–6 digits (`app/lib/pin.dart` `isValidPinFormat`; `PinStore.MAX_FAILURES = 5`, lockout cap 900 s).
- **Attack:** A person holding the unlocked phone works through the lock screen 5 PINs per lockout window. Durations escalate 30→60→120→240→480→900 s and then stay at 900 s, so the full 10⁴ space takes ≈ 21 days of continuous attempts (≈ 10 days average). That is far too slow for a casual snooper — F1 is genuinely fixed — but it is not "never", and a thief with the phone for weeks wins against a 4-digit PIN. A 6-digit PIN multiplies the work ~100× (≈ 3 years).
- **Fix:** Make 6 digits the minimum for *new* PINs (existing 4-digit PINs keep working), or nudge at set-time. Cheap, closes the tail.

### N2 — LOW — Bank OTPs can still land in the message archive (residual of F2)

- **Evidence:** `FinanceFilter.kt` `keepSms()` — a sender matching `BANK_SENDER` (YESBNK, SBI, HDFC, …) keeps the message **regardless of body**; only non-bank senders face the amount+keyword test. `CaptureStore` retains up to 500 such messages (encrypted).
- **Attack:** Bank OTP/verification SMS arrive from those same sender IDs, so the archive can hold live-format OTP texts and bank promo bodies alongside transactions. Exposure now requires defeating the at-rest encryption too (F3 fix), which is why this drops from High to Low — but the data simply doesn't need to be there: the Dart parser already rejects OTP-shaped messages (`kanakku_parser.dart` `_otpSignals`), they are kept only natively.
- **Fix:** Apply the parser's OTP-signal rejection inside `keepSms()` even for bank senders (keep the body test bypass for everything *except* OTP-shaped texts).

### N3 — LOW — At-rest encryption silently falls back to plaintext if the Keystore fails

- **Evidence:** `StoreCrypto.kt` `encrypt()` — `catch (e: Exception) { plain }`: on any Keystore error the document is stored **unencrypted and unmarked**, indistinguishable from a legacy pre-v1.0.4 value, with no signal to the user or the Dart side.
- **Attack:** On a device with a broken/rolled-back Keystore (rare, but exactly the devices most at risk), the F3 protection quietly doesn't exist while the user believes it does.
- **Fix:** Surface the failure (a settings/health flag, or refuse-and-retry on next launch) instead of storing plaintext silently. Keeping the data is the right priority — hiding the downgrade is the bug.

### N4 — LOW — No `dataExtractionRules`: device-to-device transfer nuance on Android 12+ (residual of F4)

- **Evidence:** `AndroidManifest.xml` declares `allowBackup="false"` but no `android:dataExtractionRules` (and no `fullBackupContent` for completeness).
- **Attack:** For targetSdk ≥ 31, D2D migration (Pixel/Smart Switch) is governed by data-extraction rules, and on some OEM flows app data is still copied despite `allowBackup="false"`. **Impact is heavily blunted:** CaptureStore values are AES-GCM ciphertext under a Keystore key that never migrates, so a transferred copy is unreadable on the new phone (the app treats it as corrupt and starts clean — data *loss*, not leak). The one thing that migrates in usable form is the PIN verifier prefs (`kanakku_pin`) — useless without the PIN, and now PBKDF2-stretched.
- **Fix:** Ship a `data_extraction_rules.xml` excluding the capture/pin stores from both cloud backup and device transfer, for belt-and-braces parity with the manifest's stated intent.

### N5 — LOW — Encrypted-backup passphrase minimum is only 6 characters

- **Evidence:** `main.dart` `_askPassphrase` (~L1330): "Use a passphrase of at least 6 characters." The v2 blob itself is strong (PBKDF2 120k + AES-256-GCM, see F5).
- **Attack:** The encrypted file is *designed* to live in WhatsApp/Drive/email — i.e. it will eventually sit somewhere an attacker can copy it and attack **offline, forever, at their own pace**. PBKDF2-120k slows guessing, but a human-chosen 6-character passphrase falls to a rules-based dictionary attack in hours-to-days on modest GPU hardware. (A random 6-char passphrase is a different story; users don't pick those.)
- **Fix:** Raise the minimum to 10+ characters (or 4+ words) and say why in the prompt. One-line policy change; edges toward Medium for dictionary-style passphrases.

### N6 — LOW — Build silently falls back to debug signing when the keystore is absent (NEW)

- **Evidence:** `app/android/app/build.gradle.kts` — `signingConfig = if (kanakkuHasReleaseKey) release else debug`, with the fallback kept deliberately "so the project still builds".
- **Attack:** The shipped v1.1.5 APK is correctly signed (F6 verified). But any future release built on a machine/CI where `~/.kanakku-signing/key.properties` is missing produces a **debug-signed "release" with no error or warning** — re-opening the F6 hole (anyone with the universal debug keystore could then sign a malicious update that installs over it) and silently breaking update continuity with the real key.
- **Fix:** Fail the release build when the key file is absent (keep the fallback for `debug`/`profile` build types only). Also note the gradle file hardcodes `/home/hatch/.kanakku-signing/` as the default path — fine here, worth knowing if the build machine changes.

### N7 — LOW — Fake-transaction injection via crafted SMS remains, and amounts have no ceiling (residual of F11)

- **Evidence:** `FinanceFilter.keepSms()` keeps any SMS whose body has an amount + a finance keyword (any sender), and `KanakkuParser.parse` (`parser/lib/kanakku_parser.dart`) accepts any amount > 0 — there is no sanity ceiling.
- **Attack:** Anyone who can send Guna an SMS (no spoofing needed) — "Rs. 8,50,000.00 debited from your A/c…" — plants a fake transaction that pollutes totals, budgets, budget alerts and the daily summary until he notices and removes it. A spoofed bank sender-id makes it indistinguishable from a real alert. Money never moves, entries are removable and a removed-list exists, so impact is bounded confusion/social-engineering — but the summary notification gives the fake number lock-screen-adjacent reach (content itself is now redacted, F12 fix).
- **Fix (optional):** A plausibility ceiling (e.g. flag — don't silently total — single entries above a user-set threshold), or a "quarantine" state for entries from unknown senders. Acceptable to leave as a documented design limit of SMS-based tracking; every app in this category shares it.

### N8 — INFO — Statement date parser accepts impossible dates in one branch (NEW, correctness)

- **Evidence:** `app/lib/statement.dart` `parseStatementDate()` — the `dd MMM yyyy` branch validates the month name but never range-checks the day, and Dart's `DateTime()` normalises overflow: "31 Feb 2026" silently becomes 3 Mar 2026. (The numeric `dd/mm/yyyy` branch *does* validate ranges.)
- **Attack:** None realistic — a crafted CSV can misdate its own rows. Recorded for correctness only.

### N9 — INFO — Release build has no R8/minify (NEW, defence-in-depth)

- **Evidence:** `build.gradle.kts` release block sets only the signing config; `minifyEnabled`/`shrinkResources` are absent.
- **Assessment:** The shipped logic is Dart AOT-compiled; the Kotlin layer is a thin bridge with no secrets to hide. Obfuscation would only marginally raise reverse-engineering effort. No change needed; recorded so it's a decision, not an oversight. (Release lint is also disabled — `checkReleaseBuilds = false` — worth re-enabling before any Play Store upload, as the file's own comment says.)

---

## Part 3 — Checked and found SOUND (this pass)

1. **Still no network surface.** Release manifest requests **no INTERNET** permission (present only in the dev-only debug/profile manifests); pubspec runtime deps remain just Flutter + `cupertino_icons` + the first-party parser; grep finds no HTTP client, socket, WebView, or URL-launcher in `app/lib`, `parser/lib` or Kotlin. No API keys, tokens, Firebase config or credentials anywhere in the tree (grep-verified; the only `password` hits are the gradle signing properties *names*, whose values live outside the repo).
2. **Still zero sensitive logging.** No `print`/`debugPrint` in Dart production code, no `android.util.Log` in Kotlin.
3. **Biometric unlock is implemented the careful way (new in v1.1).** Framework `BiometricPrompt`, `BIOMETRIC_STRONG`, fail-closed on every error/cancel/lockout (`MainActivity.kt`); enabling it requires a counted PIN verify + live probe + one successful prompt, in that order (`main.dart` `_toggleBiometric`); it is never offered while a PIN lockout runs, never exists without a PIN underneath (flag force-cleared when the PIN is cleared or a backup is restored — `main.dart` L1487, L5375), and disabling it also requires a counted verify.
4. **Backup never contains PIN material — re-verified for v1.1.** `backupStoreKeys` unchanged in kind (recurring added; alert state explicitly never backed up, spec §2.3). Restore never touches `PinStore`.
5. **Restore is crash-safe and decrypt-first.** Encrypted restores decrypt fully before any write; the restore-in-progress flag + restore hold on recurring rules (spec §6.2) means a mid-restore crash can't fire stale recurring entries at next launch.
6. **Parser robustness.** All parser regexes use bounded classes/quantifiers and run on SMS-length strings — no catastrophic-backtracking shapes; amounts/dates go through `tryParse` or digit-only regex groups (`statement.dart` guards `int.parse` behind `\d` matches — the one gap is N8's range check). Personal merchant rules match by substring `contains` (no user-controlled regex). CSV import is linear-time, size-capped natively at 5 MB (F10 fix), and malformed rows are skipped, not fatal.
7. **Component exposure unchanged and correct.** Only the launcher activity is exported; `SmsReceiver` exported behind `BROADCAST_SMS`; notification listener and summary receiver `exported=false`; FileProvider `exported=false` with paths limited to the exports cache; all `PendingIntent`s `FLAG_IMMUTABLE`; no deep links, no intent-extra parsing in `MainActivity`.
8. **No clipboard use anywhere** (`grep Clipboard` = 0 hits) and no data leaves except user-invoked share sheets and the mailto support intent.
9. **Demo/sample data is display-only.** `_demoEntries()`/`_demoBills()` populate the UI only while no real data exists (or right after a wipe, i.e. first-run state), under a visible "Showing sample data" banner; demo entries are never written to the native stores.
10. **Danger-zone wipe still wipes everything**, now including the recurring and alert-state documents (`CaptureStore.clearAll` + `PinStore.clear` via the single `wipeAll` channel call, which also disarms the summary alarm).

---

## Priority order for fixes (all optional hardening — nothing here is urgent)

1. **N6** — make release builds *fail* without the real keystore (one gradle change; protects every future update).
2. **N1 + N5** — two one-line policy changes: 6-digit minimum for new PINs; 10+ character backup passphrases.
3. **N2** — reject OTP-shaped texts in `FinanceFilter` even for bank senders.
4. **N3 + N4** — surface Keystore-encryption failure instead of silent plaintext; add `data_extraction_rules.xml`.
5. **N7/N8/N9** — document or polish at leisure.

*End of audit. No source files were modified.*
