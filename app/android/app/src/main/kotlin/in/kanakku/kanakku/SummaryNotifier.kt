package `in`.kanakku.kanakku

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.Calendar

/**
 * Daily summary notification (v0.5). The Dart side computes the
 * one-line summary ("Today ₹X · Month ₹Y") and stores it natively;
 * an AlarmManager alarm at ~21:00 local fires [DailySummaryReceiver],
 * which posts the stored text and re-arms for the next day. All
 * framework APIs — no notification plugin.
 */
object SummaryNotifier {
    const val CHANNEL_ID = "kanakku_daily_summary"
    private const val NOTIF_ID = 2100
    private const val ALARM_REQUEST = 2101

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Daily summary", NotificationManager.IMPORTANCE_DEFAULT
                ).apply { description = "Your Kanakku daily spend summary" }
            )
        }
    }

    /** Posts the last stored summary text right now. Returns false
     * when there is nothing stored yet. */
    fun postStored(context: Context): Boolean {
        val text = CaptureStore.summaryText(context)
        if (text.isBlank()) return false
        post(context, text)
        return true
    }

    fun post(context: Context, text: String) {
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
        // v1.0.4 (audit F12): amounts never appear on the lock
        // screen — VISIBILITY_PRIVATE hides the content there and
        // the public version shows a neutral line instead.
        val publicVersion = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Kanakku — today's spending")
            .setContentText("Your daily summary is ready")
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Kanakku — today's spending")
            .setContentText(text)
            .setStyle(android.app.Notification.BigTextStyle().bigText(text))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setVisibility(android.app.Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .build()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(NOTIF_ID, notification)
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted on Android 13+ — the
            // in-app Today card still carries the same summary.
        }
    }

    /** Next occurrence of the user's reminder time (stored by the
     * Dart side; 21:00 until the v1.0 setting changes it). */
    private fun nextTriggerMillis(context: Context): Long {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, CaptureStore.summaryHour(context))
            set(Calendar.MINUTE, CaptureStore.summaryMinute(context))
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= System.currentTimeMillis()) cal.add(Calendar.DAY_OF_YEAR, 1)
        return cal.timeInMillis
    }

    private fun alarmIntent(context: Context): PendingIntent {
        val intent = Intent(context, DailySummaryReceiver::class.java)
        return PendingIntent.getBroadcast(
            context, ALARM_REQUEST, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** Arms the next reminder-time alarm (setAndAllowWhileIdle:
     * fires close to the set time even in Doze, without the
     * exact-alarm permission). */
    fun arm(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP, nextTriggerMillis(context), alarmIntent(context)
        )
    }

    fun disarm(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(alarmIntent(context))
    }
}

/** Fires at ~21:00, posts the stored summary, re-arms for tomorrow. */
class DailySummaryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (CaptureStore.summaryOn(context)) {
            SummaryNotifier.postStored(context)
            SummaryNotifier.arm(context)
        }
    }
}

/** Re-arms the daily alarm after a reboot (alarms don't survive it). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED &&
            CaptureStore.summaryOn(context)
        ) {
            SummaryNotifier.arm(context)
        }
    }
}
