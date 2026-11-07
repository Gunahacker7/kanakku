# KANAKKU — Expense Tracker
### Project Specification v1.0 · 25 Oct 2026
**கணக்கு — "Every rupee, accounted."**

---

## 1. The idea

An expense tracker for India that logs your money **by itself**. Bank SMS and transaction emails are captured and converted into clean, categorised expenses automatically. Manual entry exists, but it is the backup — not the job.

**Reference point:** FinTraQ (₹99, manual-only, 50/30/20 budgeting). We keep its simplicity and budgeting model. We beat it on the one thing it cannot do: **automatic capture**.

**Non-negotiable core (Guna's order):** SMS auto-capture + Email auto-capture. No compromise.

## 2. Core features

### 2.1 Auto-capture — SMS (Android)
- Reads bank/UPI transaction SMS in real time (and imports history on first install)
- Parser extracts: amount, debit/credit, merchant/payee, account (last 4), balance after txn, date/time
- Launch coverage: SBI, HDFC, ICICI, Axis, Kotak, Yes Bank, Indian Bank, Canara, PNB + UPI (GPay, PhonePe, Paytm) formats
- On-device parsing: the raw SMS never leaves the phone; only the extracted transaction is stored

### 2.2 Auto-capture — Notification channel (Android)
- Bank apps and UPI apps increasingly notify instead of texting. A notification listener captures the same transactions from app notifications, through the same parser
- This is the second capture channel — together SMS + notifications cover what either alone would miss

### 2.3 Auto-capture — Email (Gmail)
- Gmail API, read-only OAuth (user can disconnect anytime)
- Parses bank transaction alerts and e-statements into the same transaction pipeline
- **Deduplication:** the same spend arriving by SMS + notification + email becomes ONE entry (matched on amount + account + time window)

### 2.4 Smart categorisation
- Merchant rules engine (Swiggy/Zomato → Food, Uber/Ola → Travel, Amazon → Shopping...)
- Auto-split into **Needs / Wants / Savings** (the FinTraQ model) with subcategories under each
- Learns from user corrections: fix a category once, it remembers the merchant forever

### 2.5 Manual add — 3 taps (backup path)
Amount → category/subcategory → note → Save. Under 5 seconds, per the reference design.

### 2.6 Salary split & budgets
- Monthly income auto-split by **50/30/20** (Needs/Wants/Savings) or custom ratio / fixed amounts; presets 50-30-20, 60-20-20, 70-20-10, 40-30-30
- Budget per category AND subcategory, with "₹X left of ₹Y" progress bars
- Alerts at 80% and 100% of any budget

### 2.7 Insights
- Month donut: Needs/Wants/Savings with Budget vs Spent bars
- Daily spend trend, top merchants, month-vs-month comparison
- **Daily expense report push** (evening): today's spends, budget health, one-line summary

### 2.8 Accounts
- Multiple bank accounts, cards, wallets, cash — balances update from SMS "Bal:" fields
- Net position on the home screen: total in, total out, left to spend this month

### 2.9 Trust features (this is a finance app — trust is the product)
- Biometric/PIN app lock
- Data encrypted at rest; parsing on-device
- Export anytime (CSV/PDF) — your data is yours
- No ads, no selling data. Ever.

## 3. Screens

1. **Onboarding** — value pitch → permissions (SMS, notifications, Gmail) each with a plain-language "why" → first import runs
2. **Home** — month ring (spent vs budget), left-to-spend, today's transactions, capture-status chips (SMS ✓ / Email ✓)
3. **Transactions** — searchable list, source icon per entry (SMS/Email/Manual), swipe to recategorise
4. **Add Expense** — the 3-tap sheet
5. **Budgets** — split setup + subcategory limits + remaining bars
6. **Insights** — donut, trends, top merchants
7. **Accounts** — balances per account/card/wallet
8. **Settings** — capture channels, categories & rules, daily report time, export, lock

## 4. Data model (core tables)

- **User** — id, email, currency, month-start day, report time
- **Account** — id, type (bank/card/wallet/cash), bank name, last4, balance
- **Transaction** — id, account_id, amount, direction (debit/credit), merchant_raw, category_id, bucket (needs/wants/savings), source (sms/notification/email/manual), source_ref (for dedupe), txn_time, note
- **Category** — id, name, bucket, icon, budget_limit
- **MerchantRule** — pattern → category_id (seeded + user-learned)
- **Budget** — month, category_id, limit, alert thresholds

## 5. Tech stack

- **App:** Flutter (one codebase; Android first, iOS later without SMS)
- **Local DB:** SQLite (Drift) — offline-first; parsing and storage work with no internet
- **Backend:** Firebase (Auth, Firestore sync, FCM for the daily report)
- **SMS:** native Android bridge (BroadcastReceiver + history import)
- **Email:** Gmail API, read-only scope, server-side fetch + parse
- **Parser:** rule/regex engine, bank-format library — designed so adding a new bank format is a data change, not a code change

## 6. The hard truth — and the plan for it

- **Play Store restricts SMS permissions.** Financial apps must declare core functionality; some trackers get rejected. Mitigations, in order: (1) file the permissions declaration with a clear finance use-case + privacy policy; (2) the notification channel (2.2) needs no SMS permission and covers much of the same data; (3) fallback distribution via direct APK if Play says no. The feature survives all three routes. [Likely]
- **iOS cannot read SMS at all** — Apple blocks it for every app. iOS version (later) = email capture + manual only. [Certain]
- **Parser maintenance is forever:** banks change SMS wording. The format library must be updatable without an app release (remote config).

## 7. Build phases

| Phase | Scope | Time |
|---|---|---|
| **0 — Setup** | Repo, Firebase project, design system (light cards, orange accent, per reference) | 3–4 days |
| **1 — MVP** | Auth, manual add (3-tap), SMS capture + parser for top 6 banks & UPI, home + transactions, basic budgets | ~2 weeks |
| **2 — Full capture** | Notification channel, Gmail capture, dedupe, merchant learning, subcategory budgets + alerts | ~1.5 weeks |
| **3 — Insights & polish** | Donut/trends, daily report push, accounts & balances, export, app lock | ~1 week |
| **4 — Launch** | Play Store submission (incl. SMS declaration), privacy policy, beta test with 10–20 users | ~1 week |
| **5 — Later** | Account Aggregator integration, iOS companion, family/shared wallets | post-launch |

**MVP total: ~4–6 weeks part-time.**

## 8. Costs & monetisation

- Google Play developer account: **$25 one-time** · Firebase free tier covers MVP scale · Apple $99/yr only when iOS starts
- **Pricing model:** Free = manual + SMS capture. **Premium ₹99 one-time** (matches FinTraQ's proven price point) or ₹49/month = email capture, daily reports, unlimited budgets, export. Recommend one-time ₹99 at launch — the reference product proves buyers pay it for far less.

## 9. Name

**Kanakku (கணக்கு)** — Tamil for accounts/ledger. Unique in the expense-tracker space, instantly understood by the Tamil + Indian audience, easy to say and spell. Tagline: *"Every rupee, accounted."*

---

*Next step on approval: Phase 0 — project setup and the design system.*
