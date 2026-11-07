package `in`.kanakku.kanakku

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Budget-alert notifications (v1.1, final_spec §4.3). Posted from
 * the Dart side via the capture channel when a budget crossing is
 * detected at app open — BudgetNotifier itself is a dumb poster,
 * exactly like [SummaryNotifier]: all threshold/count policy lives
 * in Dart (budget_alerts.dart).
 *
 * Rule 5: channel kanakku_budget_alerts, IMPORTANCE_DEFAULT, and
 * lock-screen visibility SECRET with a neutral public version —
 * the lock screen only ever shows "Budget alert — open Kanakku".
 * Bodies carry percentages only, never amounts or balances.
 */
object BudgetNotifier {
    const val CHANNEL_ID = "kanakku_budget_alerts"
    private const val NOTIF_ID = 4202

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Budget alerts", NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "Alerts when a budget crosses 80% or 100%"
                    lockscreenVisibility = android.app.Notification.VISIBILITY_SECRET
                }
            )
        }
    }

    /** Posts one aggregated budget alert. Returns false when the
     * notification could not be posted (e.g. POST_NOTIFICATIONS
     * denied on Android 13+) — the caller counts only real posts
     * against the 2-per-day cap. */
    fun post(context: Context, title: String, body: String): Boolean {
        ensureChannel(context)
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
        }
        val publicVersion = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Budget alert")
            .setContentText("Budget alert — open Kanakku")
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(android.app.Notification.BigTextStyle().bigText(body))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setVisibility(android.app.Notification.VISIBILITY_SECRET)
            .setPublicVersion(publicVersion)
            .build()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return try {
            nm.notify(NOTIF_ID, notification)
            true
        } catch (e: SecurityException) {
            false
        }
    }
}
