# Kanakku (கணக்கு)

Personal finance / expense tracker for Android. Kanakku automatically captures
bank and UPI transactions from SMS and notifications, categorises them, and
turns them into balances, budgets and insights — no manual entry needed for
day-to-day spending, and everything stays on the device.

## Features

- **Auto-capture** — bank/UPI SMS and app notifications are parsed into
  transactions and de-duplicated across channels
- **Account balances & card bills** — latest balance per account; credit-card
  bills (HDFC, SBI Card, ICICI, Axis, Kotak) with days-left reminders
- **Manual entries** — expenses and income (Salary, Bonus, Freelance,
  Interest, Rental, Refund/Cashback, Gift, custom), with date picker,
  payment mode, note and tag; durable saves with failure rollback
- **Budgets & insights** — editable category budgets that follow your
  month-start day, spending overview, 50/30/20 breakdown, top categories
- **Split bills** — equal or custom shares, per-person balances, settle/undo
- **Bank statements** — upload a bank CSV (HDFC/ICICI/SBI) for import + analysis
- **Backup & restore** — one JSON file holds everything; restore on any phone
  (the app-lock PIN is never exported)
- **App lock** — PIN gate with balance privacy (₹••• until unlocked)
- **Daily summary** — "Today" card plus a scheduled evening notification
- **Settings** — profile, default payment mode/categories, dark theme,
  12/24h time, daily reminder time, categories manager with personal
  merchant rules, tags, danger-zone wipe
- **Design** — MyWallet-style serif UI, glass (frosted) bottom bar,
  Fraunces display type + Manrope UI type

## Project layout

- `app/` — Flutter application (Android native bridge in Kotlin for SMS /
  notification capture and on-device stores)
- `parser/` — pure-Dart transaction parser package (SMS/notification text →
  structured transactions, categories, card bills)
- `KANAKKU-SPEC.md` — product specification

## Build

Requires Flutter 3.47+, JDK 17 and the Android SDK.

```sh
cd parser && dart test
cd ../app && flutter test
flutter build apk --release --split-per-abi
```

## Note on binary assets

The text source is published here. Binary assets (the Fraunces/Manrope font
files in `app/assets/fonts/` and the launcher icon PNGs) are distributed with
the release APK; both font families are open-licence (OFL) and can be fetched
from Google Fonts.

## Status

Current release: **v1.1.5** — download the APK from
[GitHub Releases](https://github.com/Gunahacker7/kanakku/releases/tag/v1.1.5).
Built and maintained by Gunasekar E.
