# KANAKKU REDESIGN — v1.2 design spec (Guna's order, 22 Nov 2026)

Route chosen by Guna: **Option 2 — full visual reskin + NEW Subscriptions module.**
Reference images: `docs/redesign-reference/01–05` (subscription-tracker app screenshots Guna sent).

## Design system (from references)
- Background: warm light grey `#F3F3F0`-ish; surfaces pure white.
- Cards: white, very rounded (radius ~24), soft/no shadow, generous padding.
- Primary/accent: deep green (`#1E6B4F`-ish); amounts in green on list rows; pastel sage tints for chart bars and icon tiles (each brand/category gets a soft tinted tile).
- Typography: clean sans; big bold amounts (₹ with decimals small); grey secondary text; section titles bold black.
- Pills/badges: small rounded pills (e.g. "8 Active" grey, "4 Payments" amber tint, "↑40% vs Sep" pink tint, "Active" green tint, "Renews" green tint).
- Bottom nav: **3 tabs only — Home · Calendar · Settings**, active tab = soft pill highlight behind icon.
- Floating action: circular deep-green "+" button (top-right on Home, per reference).
- Progress bars: rounded, green fill on pale track.

## Screen mapping (Kanakku features stay; auto-capture core untouched)
1. **Home** — greeting header (avatar + "Good Morning/Evening" + user name) + green + button; two stat cards (This Month Spent / Budget Left — or Monthly Average / Due in 30 Days style); "Monthly Spending" bar-chart card with 6M/1Y toggle + % vs last month badge; below: "Upcoming" renewals preview + recent transactions list (icon tile, name, sub-line, amount right).
2. **Add New** — category chips row on top; icon grid sections (Essentials-style grid for expense categories + Popular merchants); same grid pattern serves Add Expense and Add Subscription.
3. **Calendar** — month grid; days with payments carry tiny category/brand icons; header summary "N payments · ₹X"; tapping a day lists that day's transactions + renewals below; month nav arrows + "This month" pill.
4. **Details** (transaction/subscription) — tinted header with big icon, name, amount + cycle; renewal/status card with progress bar (Day X of Y, Active badge); Total Spent card; rows: Billing History, Category, Website/Account; Edit + Delete in header; "Mark as Cancelled" (subscriptions) at bottom.
5. **Settings** — same card language; existing Kanakku settings content, reskinned.
6. **Home-screen widget (Android)** — "Upcoming" renewals widget per reference 01: white card, list of next renewals (name, renews-in text, amount, Monthly/Yearly), Refresh pill, "Not updating? Open the app to refresh." footer. Phase 3 (native Kotlin widget + data bridge).

## Subscriptions module (NEW)
- Model: name, brand/category, amount, cycle (Monthly/Yearly/custom), first-billing date, next renewal (computed), category, status (Active/Cancelled), total spent (computed from cycles elapsed + linked captured transactions where matched).
- Build on existing `lib/recurring.dart` if it fits; storage in the existing encrypted store pattern.
- Add flow: reference-03 grid — Essentials (Gym, Wi-Fi, EMI, SIP, Rent, Fee, TV/DTH, Mobile Plan, PUC…) + Popular brands (Spotify, YouTube Premium, Netflix, Prime Video, iCloud, Airtel, Jio Hotstar, Canva, ChatGPT, Claude…) + custom.
- Renewal reminders via existing notifier pattern (BudgetNotifier/SummaryNotifier style).
- Auto-capture link: when an SMS/email capture matches a subscription merchant + amount, mark that cycle as billed (no duplicate expense entry — dedupe rules already exist).
- Details screen per reference 05, incl. billing history and Mark as Cancelled.

## Phases
1. Design system (theme.dart) + 3-tab nav shell + Home reskin.
2. Subscriptions module (model, add grid, list, details, renewal engine) + Calendar screen.
3. Add/Details/Settings reskins + Android widget + full build + QA.

## Guardrails
- SMS + Email auto-capture = non-negotiable core; do not break capture, parser, dedupe, backup/crypto.
- Version bump from v1.1.5 → v1.2.0.
- Verify: `flutter analyze` clean + release APK builds. No emulator in VM — UI verified by code review + widget tests where practical.

## Phase 3 completion (22 Nov 2026)
- **Reskins done** (look only — no behaviour/data-flow/navigation changes): manual Add sheet in main.dart (section-title header, amount style, pill chips, filled text wells, radius-20 primary button), transaction rows (KIconTile tiles, PillBadge tag/recurring chips, amount style), Transactions page (KPageHeader, KCard list, pill tag filters), Budgets page (KCard budget cards, rounded progress with the 80% tick kept, salary-split card), Insights page (KCard stat/overview/where-it-goes cards, capsule weekly bars in sage, RoundedProgress category rows), Split sheet + Splits page (well fields, PillBadge "Settled", KCard balances/cards), Settings page content (profile KCard, rows rebuilt as KCard + tinted icon tiles, danger-zone card), and the Edit-entry / Edit-budget dialogs (radius-24, well fields, green primary). theme.dart gained the shared pieces: `KPageHeader`, `KIconTile`, `KanakkuTheme.wellDecoration`, `KanakkuTheme.chipShape/chipSide`; KCard now puts its child on a transparent Material so ListTiles inside cards paint ink correctly.
- **Android "Upcoming" widget done**: native Kotlin `UpcomingWidget` (RemoteViews) + layout/drawables/widget-info XML, registered in the manifest. It reads the subscriptions document read-only via `CaptureStore.subscriptions()` (decrypts transparently), mirrors the Dart renewal engine natively (nominal-day clamping, custom-day steps, strictly-after-today, cancelled excluded), and renders up to 6 renewals with "Renews tomorrow / in N days / on <date>" + "Starts on …" for not-yet-started subs, Indian-grouped ₹ amounts and Monthly/Yearly cycle labels. Refresh: Refresh pill broadcast, 30-min `updatePeriodMillis`, and an `updateAll` trigger fired from MainActivity after every successful `setSubscriptions` write and after `wipeAll`. Empty state text when there are no subscriptions; tapping the widget opens the app.
- **QA**: `flutter analyze` clean; `flutter test` **150/150 pass** (149 baseline + 1 new `test/reskin_pages_test.dart` covering the reskinned Transactions/Budgets/Insights/Splits pages' reachability and rendering). No existing test needed changes.
- **Release build: NOT completed in this run.** `flutter build apk --release` was attempted once and Gradle failed with a network/dependency-resolution error (this VM's egress-proxy TLS problem); a follow-up approval to retry timed out, so no new release APK exists yet (the APKs under build/app/outputs are stale, dated 7 Nov). Retry path: run the project's `build-loop.py` fetch mechanism (harvests missing artifact coords into ~/local-maven) and then `flutter build apk --release` again.
- **Not verified**: no emulator/device in the VM, so the widget's on-launcher rendering and the reskinned screens were verified by code review + widget tests only, not visually.
