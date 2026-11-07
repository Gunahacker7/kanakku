package `in`.kanakku.kanakku

/**
 * Native pre-filter for captured messages (v1.0.4, audit F2). Before
 * this, EVERY incoming SMS and every notification from a vaguely
 * finance-looking package was archived verbatim — OTPs and personal
 * messages included. Now a message is persisted only when it is
 * finance-plausible:
 *
 *   the text contains a currency/amount pattern
 *   (Rs. 1,200 / INR 500 / ₹750 / 500.00 debited …)
 *   AND at least one finance keyword
 *   (debited, credited, UPI, balance, bill due, a/c, …)
 *
 * The rules mirror the Dart parser's heuristics in spirit and are
 * deliberately conservative — when in doubt, KEEP:
 *  - messages from recognisable bank sender-ids (VM-HDFCBK, AD-SBI…)
 *    are kept regardless of body, so an oddly-worded real bank alert
 *    is never dropped;
 *  - anything matching both signals is kept even if the parser later
 *    discards it (e.g. a card bill summary, which CardBillParser
 *    owns). Keeping is cheap; dropping a real transaction is not.
 */
object FinanceFilter {
    private val AMOUNT = Regex(
        """(?i)(?:rs\.?|inr|₹)\s*:?\s*-?\s*[\d,]+(?:\.\d{1,2})?""" +
            """|[\d,]+(?:\.\d{1,2})?\s*(?:rs\.?|inr)\b""" +
            """|\b[\d,]+\.\d{2}\s*(?:debited|credited)\b"""
    )

    private val KEYWORD = Regex(
        """(?i)\b(debited|credited|debit|credit|upi|balance|bal|a/c|acct|account|card|""" +
            """withdrawn|deposited|deposit|spent|paid|received|refund|bill|due|emi|""" +
            """transaction|txn|neft|imps|rtgs|atm|cheque|check|payment|transferred|""" +
            """transfer|salary|pension|interest|charge|fee|overdraft|loan|premium|""" +
            """recharge|wallet|statement|minimum|total amt)\b"""
    )

    /** Bank SMS sender-id fragments (from the parser's sender map,
     * plus the major billers) — a hit here keeps the message. */
    private val BANK_SENDER = Regex(
        """(?i)(YESBNK|YESBANK|SBI|HDFC|ICICI|AXIS|KOTAK|INDBNK|CANARA|PNB|BOB|""" +
            """IDFC|FEDERL|IOB|BARODA|UBI|BOI|CITI|HSBC|AMEX|SBICARD|PAYTM|""" +
            """PHONEPE|GPAY|BHIM|CRED|MOBIKWIK)"""
    )

    /** True when [body] looks like a finance message worth keeping. */
    fun isFinanceText(body: String): Boolean {
        if (body.isBlank()) return false
        return AMOUNT.containsMatchIn(body) && KEYWORD.containsMatchIn(body)
    }

    /** SMS gate: known bank sender ⇒ keep; otherwise the body must
     * pass the amount+keyword test. */
    fun keepSms(sender: String, body: String): Boolean {
        if (body.isBlank()) return false
        if (BANK_SENDER.containsMatchIn(sender)) return true
        return isFinanceText(body)
    }
}
