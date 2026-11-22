package `in`.kanakku.kanakku

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Home-screen "Upcoming" widget (v1.2 Phase 3, REDESIGN-SPEC
 * screen 6 / reference 01): the next subscription renewals as a
 * white rounded card — title + "Updated …" line, a Refresh pill,
 * renewal rows (name, renews text, green amount, cycle), and the
 * "Not updating? Open the app to refresh." footer.
 *
 * Data: reads the SAME subscriptions document the app writes,
 * through [CaptureStore.subscriptions] (which decrypts
 * transparently) — read-only, no store changes. The renewal maths
 * below mirrors lib/subscriptions.dart exactly: nominal-day
 * monthly/yearly stepping clamped to the month's last day, custom
 * day steps, a bill landing today counts as billed (next renewal
 * is strictly after today), cancelled subscriptions never renew.
 *
 * Refresh paths: updatePeriodMillis (30 min), the Refresh pill
 * (broadcast to this provider), and [updateAll] called from
 * MainActivity after every successful setSubscriptions write.
 */
class UpcomingWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) updateWidget(context, appWidgetManager, id)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) updateAll(context)
    }

    companion object {
        private const val ACTION_REFRESH = "in.kanakku.kanakku.WIDGET_REFRESH"
        private const val MAX_ROWS = 6

        private val ROW_IDS = intArrayOf(
            R.id.widget_row_1, R.id.widget_row_2, R.id.widget_row_3,
            R.id.widget_row_4, R.id.widget_row_5, R.id.widget_row_6,
        )
        private val NAME_IDS = intArrayOf(
            R.id.widget_name_1, R.id.widget_name_2, R.id.widget_name_3,
            R.id.widget_name_4, R.id.widget_name_5, R.id.widget_name_6,
        )
        private val RENEWS_IDS = intArrayOf(
            R.id.widget_renews_1, R.id.widget_renews_2, R.id.widget_renews_3,
            R.id.widget_renews_4, R.id.widget_renews_5, R.id.widget_renews_6,
        )
        private val AMOUNT_IDS = intArrayOf(
            R.id.widget_amount_1, R.id.widget_amount_2, R.id.widget_amount_3,
            R.id.widget_amount_4, R.id.widget_amount_5, R.id.widget_amount_6,
        )
        private val CYCLE_IDS = intArrayOf(
            R.id.widget_cycle_1, R.id.widget_cycle_2, R.id.widget_cycle_3,
            R.id.widget_cycle_4, R.id.widget_cycle_5, R.id.widget_cycle_6,
        )

        private val MONTH_ABBR = arrayOf(
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        )

        /** Refreshes every placed instance of this widget. */
        fun updateAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(
                ComponentName(context, UpcomingWidget::class.java),
            )
            for (id in ids) updateWidget(context, mgr, id)
        }

        private fun updateWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_upcoming)

            // Tap anywhere (root or a row) opens the app.
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                val openApp = PendingIntent.getActivity(
                    context, 0, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(R.id.widget_root, openApp)
                for (rowId in ROW_IDS) {
                    views.setOnClickPendingIntent(rowId, openApp)
                }
            }

            // Refresh pill: broadcast back to this provider.
            val refreshIntent = Intent(context, UpcomingWidget::class.java)
                .setAction(ACTION_REFRESH)
            val refresh = PendingIntent.getBroadcast(
                context, 1, refreshIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_refresh, refresh)

            val now = Date()
            val updatedFmt = SimpleDateFormat("MMM d, h:mm a", Locale.US)
            views.setTextViewText(
                R.id.widget_updated,
                "Updated ${updatedFmt.format(now)}",
            )

            val today = todayDays(now)
            val upcoming = upcomingRenewals(context, today)
            views.setViewVisibility(
                R.id.widget_empty,
                if (upcoming.isEmpty()) View.VISIBLE else View.GONE,
            )
            for (i in 0 until MAX_ROWS) {
                val item = upcoming.getOrNull(i)
                views.setViewVisibility(
                    ROW_IDS[i],
                    if (item == null) View.GONE else View.VISIBLE,
                )
                if (item != null) {
                    views.setTextViewText(NAME_IDS[i], item.name)
                    views.setTextViewText(RENEWS_IDS[i], item.renewsText(today))
                    views.setTextViewText(AMOUNT_IDS[i], formatInr(item.amountPaise))
                    views.setTextViewText(CYCLE_IDS[i], item.cycleLabel)
                }
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }

        // ---- data ------------------------------------------------

        private class UpcomingItem(
            val name: String,
            val nextDays: Long,
            val amountPaise: Long,
            val cycleLabel: String,
            val startsInFuture: Boolean,
        ) {
            fun renewsText(today: Long): String {
                if (startsInFuture) return "Starts on ${fmtDate(nextDays)}"
                val inDays = nextDays - today
                return when {
                    inDays == 1L -> "Renews tomorrow"
                    inDays in 2..7 -> "Renews in $inDays days"
                    else -> "Renews on ${fmtDate(nextDays)}"
                }
            }
        }

        /** Active subscriptions with a future renewal, soonest
         * first (name breaks ties) — mirrors Dart upcomingRenewals. */
        private fun upcomingRenewals(
            context: Context,
            today: Long,
        ): List<UpcomingItem> {
            val json = runCatching { CaptureStore.subscriptions(context) }
                .getOrDefault("")
            val doc = try {
                JSONObject(json)
            } catch (e: Exception) {
                null
            } ?: return emptyList()
            val arr = doc.optJSONArray("subscriptions") ?: return emptyList()
            val out = mutableListOf<UpcomingItem>()
            for (i in 0 until arr.length()) {
                val sub = arr.optJSONObject(i) ?: continue
                if (sub.optString("status") == "cancelled") continue
                val firstStr = sub.optString("firstBillingDate")
                if (firstStr.isEmpty()) continue
                val first = parseDateDays(firstStr) ?: continue
                val cycle = sub.optString("cycle").ifEmpty { "monthly" }
                val customDays = asInt(sub.opt("customDays"), 30)
                val next = nextRenewalDays(first, cycle, customDays, today)
                    ?: continue
                out.add(
                    UpcomingItem(
                        name = sub.optString("name"),
                        nextDays = next,
                        amountPaise = asLong(sub.opt("amountPaise"), 0),
                        cycleLabel = cycleLabel(cycle, customDays),
                        startsInFuture = first > today,
                    ),
                )
            }
            out.sortWith(compareBy({ it.nextDays }, { it.name }))
            return out.take(MAX_ROWS)
        }

        private fun cycleLabel(cycle: String, customDays: Int): String =
            when (cycle) {
                "yearly" -> "Yearly"
                "customDays" -> if (customDays == 1) "Daily" else "Every $customDays days"
                else -> "Monthly"
            }

        // ---- renewal engine (mirrors lib/subscriptions.dart) -----

        /** First billing date strictly after [today]; a bill
         * landing today already counts as billed. */
        private fun nextRenewalDays(
            first: Long,
            cycle: String,
            customDaysRaw: Int,
            today: Long,
        ): Long? {
            if (first > today) return first
            var guard = 0
            when (cycle) {
                "customDays" -> {
                    var step = customDaysRaw
                    if (step < 1) step = 1
                    var d = first
                    while (d <= today && guard++ < 100_000) d += step
                    return if (d > today) d else null
                }
                "yearly" -> {
                    val (fy, fm, fd) = civilFromDays(first)
                    var year = fy
                    while (guard++ < 10_000) {
                        val day = minOf(fd, lastDayOfMonth(year, fm))
                        val d = daysFromCivil(year, fm, day)
                        if (d > today) return d
                        year++
                    }
                    return null
                }
                else -> { // monthly
                    val (fy, fm, fd) = civilFromDays(first)
                    var monthIdx = fy * 12 + (fm - 1)
                    while (guard++ < 100_000) {
                        val y = monthIdx / 12
                        val m = monthIdx % 12 + 1
                        val day = minOf(fd, lastDayOfMonth(y, m))
                        val d = daysFromCivil(y, m, day)
                        if (d > today) return d
                        monthIdx++
                    }
                    return null
                }
            }
        }

        // ---- dates (proleptic Gregorian, day granularity) --------

        private fun todayDays(now: Date): Long {
            val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            return parseDateDays(fmt.format(now)) ?: 0L
        }

        /** Strict yyyy-mm-dd parse (mirrors Dart parseDateStr:
         * real calendar dates only). Returns epoch days. */
        private fun parseDateDays(s: String): Long? {
            val m = Regex("""^(\d{4})-(\d{2})-(\d{2})$""")
                .matchEntire(s.trim()) ?: return null
            val y = m.groupValues[1].toInt()
            val mo = m.groupValues[2].toInt()
            val d = m.groupValues[3].toInt()
            if (mo < 1 || mo > 12 || d < 1 || d > lastDayOfMonth(y, mo)) {
                return null
            }
            return daysFromCivil(y, mo, d)
        }

        private fun lastDayOfMonth(year: Int, month: Int): Int {
            val first = daysFromCivil(year, month, 1)
            val next = if (month == 12) {
                daysFromCivil(year + 1, 1, 1)
            } else {
                daysFromCivil(year, month + 1, 1)
            }
            return (next - first).toInt()
        }

        /** 'Dec 1, 2026' (mirrors Dart fmtSubDate). */
        private fun fmtDate(days: Long): String {
            val (y, m, d) = civilFromDays(days)
            return "${MONTH_ABBR[m - 1]} $d, $y"
        }

        private fun daysFromCivil(y0: Int, m: Int, d: Int): Long {
            val y = if (m <= 2) y0 - 1 else y0
            val era = Math.floorDiv(y, 400)
            val yoe = y - era * 400
            val mp = (m + 9) % 12
            val doy = (153 * mp + 2) / 5 + d - 1
            val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146097L + doe - 719468L
        }

        private fun civilFromDays(z0: Long): Triple<Int, Int, Int> {
            val z = z0 + 719468L
            val era = Math.floorDiv(z, 146097L)
            val doe = (z - era * 146097L).toInt()
            val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
            val y = yoe + (era * 400L).toInt()
            val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            val mp = (5 * doy + 2) / 153
            val d = doy - (153 * mp + 2) / 5 + 1
            val m = if (mp < 10) mp + 3 else mp - 9
            return Triple(if (m <= 2) y + 1 else y, m, d)
        }

        // ---- formatting ------------------------------------------

        /** Indian-grouped ₹ from paise (mirrors KanakkuTheme.inr
         * with the default full-decimals format: decimals only
         * when the amount has a paise fraction). */
        private fun formatInr(paise: Long): String {
            val neg = paise < 0
            val abs = kotlin.math.abs(paise)
            val whole = abs / 100
            val frac = abs % 100
            val grouped = indianGrouping(whole.toString())
            val body = if (frac == 0L) {
                "₹$grouped"
            } else {
                "₹$grouped.${frac.toString().padStart(2, '0')}"
            }
            return if (neg) "-$body" else body
        }

        private fun indianGrouping(digits: String): String {
            if (digits.length <= 3) return digits
            val tail = digits.substring(digits.length - 3)
            var head = digits.substring(0, digits.length - 3)
            val parts = mutableListOf<String>()
            while (head.length > 2) {
                parts.add(0, head.substring(head.length - 2))
                head = head.substring(0, head.length - 2)
            }
            if (head.isNotEmpty()) parts.add(0, head)
            return parts.joinToString(",") + "," + tail
        }

        /** Dart _asInt/_asLong equivalent: numbers pass through,
         * strings are parsed, anything else falls back. */
        private fun asInt(v: Any?, dflt: Int): Int = when (v) {
            is Number -> v.toInt()
            is String -> v.toIntOrNull() ?: dflt
            else -> dflt
        }

        private fun asLong(v: Any?, dflt: Long): Long = when (v) {
            is Number -> v.toLong()
            is String -> v.toLongOrNull() ?: dflt
            else -> dflt
        }
    }
}
