package `in`.kanakku.kanakku

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * On-device store for captured messages. Live SMS (via SmsReceiver) and
 * bank/UPI notifications (via KanakkuNotificationListener) are appended
 * here as JSON; the Dart side pulls them through the MethodChannel and
 * runs them through the same parser as inbox SMS. Nothing leaves the
 * phone — parsing and storage are fully on-device.
 *
 * v1.0.4: every JSON document below is encrypted at rest with a
 * Keystore-held AES-GCM key (see [StoreCrypto]). Values written by
 * older versions are legacy plaintext: reads pass them through and
 * the next write re-stores them encrypted.
 */
object CaptureStore {
    private const val PREFS = "kanakku_capture"
    private const val KEY_SMS = "sms_store"
    private const val KEY_NOTIF = "notif_store"
    private const val KEY_MANUAL = "manual_store"
    private const val KEY_REMOVED = "removed_store"
    private const val KEY_SPLITS = "splits_store"
    private const val KEY_BUDGETS = "budgets_store"
    private const val KEY_STATEMENT = "statement_store"
    private const val KEY_SUMMARY = "daily_summary_text"
    private const val KEY_SUMMARY_ON = "daily_summary_on"
    private const val KEY_SUMMARY_HOUR = "daily_summary_hour"
    private const val KEY_SUMMARY_MIN = "daily_summary_minute"
    private const val KEY_SETTINGS = "settings_store"
    private const val KEY_CATEGORIES = "categories_store"
    private const val KEY_MIGRATED_V104 = "migrated_v104"
    private const val KEY_RECURRING = "recurring_store"
    private const val KEY_ALERT_STATE = "alert_state_store"
    private const val KEY_MIGRATED_V110 = "migrated_v110"
    private const val MAX_ITEMS = 500

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Reads a document key, transparently decrypting v1.0.4 values
     * and passing legacy plaintext through. */
    private fun getDoc(context: Context, key: String, default: String): String {
        val raw = prefs(context).getString(key, null) ?: return default
        return StoreCrypto.decrypt(raw, default)
    }

    /** Writes a document key, encrypted. Returns the commit result. */
    private fun putDocCommit(context: Context, key: String, value: String): Boolean =
        prefs(context).edit()
            .putString(key, StoreCrypto.encrypt(value)).commit()

    private fun putDoc(context: Context, key: String, value: String) {
        prefs(context).edit()
            .putString(key, StoreCrypto.encrypt(value)).apply()
    }

    @Synchronized
    private fun append(context: Context, key: String, item: JSONObject) {
        runV104Migrations(context)
        val arr = JSONArray(getDoc(context, key, "[]"))
        arr.put(item)
        while (arr.length() > MAX_ITEMS) arr.remove(0)
        putDoc(context, key, arr.toString())
    }

    fun appendSms(context: Context, sender: String, body: String, ts: Long) {
        append(context, KEY_SMS, JSONObject()
            .put("sender", sender).put("body", body).put("ts", ts))
    }

    fun appendNotification(context: Context, pkg: String, title: String, text: String, ts: Long) {
        append(context, KEY_NOTIF, JSONObject()
            .put("pkg", pkg).put("title", title).put("text", text).put("ts", ts))
    }

    fun sms(context: Context): String = getDoc(context, KEY_SMS, "[]")
    fun notifications(context: Context): String = getDoc(context, KEY_NOTIF, "[]")
    fun manual(context: Context): String = getDoc(context, KEY_MANUAL, "[]")
    fun setManual(context: Context, json: String): Boolean =
        putDocCommit(context, KEY_MANUAL, json)

    /** Transactions the user removed as spam/fake (JSON from the Dart side). */
    fun removed(context: Context): String = getDoc(context, KEY_REMOVED, "[]")
    fun setRemoved(context: Context, json: String) {
        putDoc(context, KEY_REMOVED, json)
    }

    /** Split bills (JSON from the Dart side, v0.5). */
    fun splits(context: Context): String = getDoc(context, KEY_SPLITS, "[]")
    fun setSplits(context: Context, json: String) {
        putDoc(context, KEY_SPLITS, json)
    }

    /** User-edited monthly category budgets (JSON map, v0.7). */
    fun budgets(context: Context): String = getDoc(context, KEY_BUDGETS, "{}")
    fun setBudgets(context: Context, json: String) {
        putDoc(context, KEY_BUDGETS, json)
    }

    /** Imported bank-statement transactions (JSON from Dart, v0.7). */
    fun statement(context: Context): String = getDoc(context, KEY_STATEMENT, "[]")
    fun setStatement(context: Context, json: String) {
        putDoc(context, KEY_STATEMENT, json)
    }

    /** Last daily-summary one-liner computed by the Dart side; the
     * 21:00 alarm receiver posts exactly this text (v0.5). */
    fun summaryText(context: Context): String = getDoc(context, KEY_SUMMARY, "")
    fun setSummaryText(context: Context, text: String) {
        putDoc(context, KEY_SUMMARY, text)
    }
    fun summaryOn(context: Context): Boolean = prefs(context).getBoolean(KEY_SUMMARY_ON, false)
    fun setSummaryOn(context: Context, on: Boolean) {
        prefs(context).edit().putBoolean(KEY_SUMMARY_ON, on).apply()
    }

    /** Daily reminder time (v1.0 setting), persisted so the boot
     * re-arm and the receiver schedule at the user's chosen time. */
    fun summaryHour(context: Context): Int = prefs(context).getInt(KEY_SUMMARY_HOUR, 21)
    fun summaryMinute(context: Context): Int = prefs(context).getInt(KEY_SUMMARY_MIN, 0)
    fun setSummaryTime(context: Context, hour: Int, minute: Int) {
        prefs(context).edit()
            .putInt(KEY_SUMMARY_HOUR, hour.coerceIn(0, 23))
            .putInt(KEY_SUMMARY_MIN, minute.coerceIn(0, 59))
            .apply()
    }

    /** App settings document (JSON from Dart, v1.0). */
    fun settings(context: Context): String = getDoc(context, KEY_SETTINGS, "{}")
    fun setSettings(context: Context, json: String) {
        putDoc(context, KEY_SETTINGS, json)
    }

    /** Personal categories + merchant rules (JSON from Dart, v1.0). */
    fun categories(context: Context): String = getDoc(context, KEY_CATEGORIES, "{}")
    fun setCategories(context: Context, json: String) {
        putDoc(context, KEY_CATEGORIES, json)
    }

    /** Recurring-rules document (JSON from Dart, v1.1). Commit
     * write, like the manual store: an engine pass must not report
     * success for a write that did not land. */
    fun recurring(context: Context): String = getDoc(context, KEY_RECURRING, "")
    fun setRecurring(context: Context, json: String): Boolean =
        putDocCommit(context, KEY_RECURRING, json)

    /** Budget-alert state (JSON from Dart, v1.1). Device-local
     * bookkeeping; never part of a backup. */
    fun alertState(context: Context): String = getDoc(context, KEY_ALERT_STATE, "")
    fun setAlertState(context: Context, json: String) {
        putDoc(context, KEY_ALERT_STATE, json)
    }

    /**
     * One-time v1.1 migration (final_spec §6.1): seed the two new
     * documents when — and only when — they are absent. Idempotent:
     * guarded by [KEY_MIGRATED_V110], writes nothing when the docs
     * already exist, and never touches an existing transaction.
     * The Dart side repeats the same absence check before the Shell
     * loads, so the seed lands even if this runs later.
     */
    @Synchronized
    fun runV110Migrations(context: Context) {
        val p = prefs(context)
        if (p.getBoolean(KEY_MIGRATED_V110, false)) return
        if (!p.contains(KEY_RECURRING)) {
            putDoc(context, KEY_RECURRING, "{\"nextRuleSeq\":1,\"rules\":[]}")
        }
        if (!p.contains(KEY_ALERT_STATE)) {
            putDoc(context, KEY_ALERT_STATE, "{}")
        }
        p.edit().putBoolean(KEY_MIGRATED_V110, true).apply()
    }

    /**
     * One-time v1.0.4 migration (audit F2): purge already-archived
     * SMS / notifications that fail the new finance filter, so the
     * pre-filter archive of OTPs and personal messages does not
     * survive the upgrade. Runs at most once; also triggered from
     * MainActivity.onCreate and before every append.
     */
    @Synchronized
    fun runV104Migrations(context: Context) {
        val p = prefs(context)
        if (p.getBoolean(KEY_MIGRATED_V104, false)) return
        purgeArchive(context, KEY_SMS) { item ->
            FinanceFilter.keepSms(
                item.optString("sender"), item.optString("body")
            )
        }
        purgeArchive(context, KEY_NOTIF) { item ->
            KanakkuNotificationListener.isFinancePackage(item.optString("pkg")) &&
                FinanceFilter.isFinanceText(
                    "${item.optString("title")} ${item.optString("text")}".trim()
                )
        }
        p.edit().putBoolean(KEY_MIGRATED_V104, true).apply()
    }

    private fun purgeArchive(context: Context, key: String, keep: (JSONObject) -> Boolean) {
        try {
            val arr = JSONArray(getDoc(context, key, "[]"))
            val kept = JSONArray()
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                if (keep(item)) kept.put(item)
            }
            if (kept.length() != arr.length()) putDoc(context, key, kept.toString())
        } catch (e: Exception) {
            // A corrupt archive must never break app start; the raw
            // value stays and the migration flag is still set so we
            // don't loop on it every launch.
        }
    }

    /** Danger zone: erase every key in this store. The PIN lives in
     * PinStore and is cleared separately by the same flow. */
    fun clearAll(context: Context) {
        prefs(context).edit().clear().apply()
    }
}
