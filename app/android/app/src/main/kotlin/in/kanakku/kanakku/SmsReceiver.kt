package `in`.kanakku.kanakku

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * Captures incoming SMS live (even when the app is closed) into the
 * store — but only finance-plausible ones (v1.0.4, audit F2). Before
 * this, every SMS the phone received, OTPs and personal messages
 * included, was archived verbatim.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        for (msg in Telephony.Sms.Intents.getMessagesFromIntent(intent)) {
            val sender = msg.originatingAddress ?: ""
            val body = msg.messageBody ?: ""
            if (!FinanceFilter.keepSms(sender, body)) continue
            CaptureStore.appendSms(context, sender, body, msg.timestampMillis)
        }
    }
}
