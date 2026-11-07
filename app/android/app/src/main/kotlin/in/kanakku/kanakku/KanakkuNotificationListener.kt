package `in`.kanakku.kanakku

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Captures notifications from banking / UPI apps into the store.
 * Bank apps notify far more reliably than they SMS, so this channel
 * closes the capture gap.
 *
 * v1.0.4 (audit F11): the gate is now a STRICT package allowlist —
 * the old substring matching (any package containing "bank"/"upi"/
 * "pay"/"wallet") plus shopping/food apps archived non-finance
 * notifications and let lookalike apps inject fake transactions.
 * The message body must additionally pass the same finance filter
 * as SMS (audit F2), so a bank app's promo notification is not
 * archived either.
 */
class KanakkuNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val pkg = sbn.packageName ?: return
        if (!isFinancePackage(pkg)) return
        val extras = sbn.notification.extras
        val title = extras.getCharSequence("android.title")?.toString() ?: ""
        val text = extras.getCharSequence("android.bigText")?.toString()
            ?: extras.getCharSequence("android.text")?.toString() ?: ""
        if (text.isBlank() && title.isBlank()) return
        if (!FinanceFilter.isFinanceText("$title $text".trim())) return
        CaptureStore.appendNotification(applicationContext, pkg, title, text, sbn.postTime)
    }

    companion object {
        /** Exact allowlist: UPI apps, wallets and the major Indian
         * banks the parser targets. Nothing else is recorded. */
        private val KNOWN = setOf(
            // UPI / payments
            "com.google.android.apps.nbu.paisa.user", // Google Pay
            "com.phonepe.app", // PhonePe
            "net.one97.paytm", // Paytm
            "in.org.npci.upiapp", // BHIM
            "com.dreamplug.androidapp", // CRED
            "com.mobikwik_new", // Mobikwik wallet
            // Banks
            "com.csam.icici.bank.imobile", // ICICI iMobile
            "com.sbi.lotza.lotza", // SBI YONO lite / LOTS
            "com.sbi.SBIFreedomPlus", // SBI
            "com.axis.mobile", // Axis
            "com.kotak811mobilebankingapp.instantsavingsupiscanandpayrecharge", // Kotak 811
            "com.yesbank.YESMOBILE", // Yes Bank
            "com.fss.hdfcbank", // HDFC
            "com.hdfcbank.android.now", // HDFC NOW
        )

        fun isFinancePackage(pkg: String): Boolean = pkg in KNOWN
    }
}
