package `in`.kanakku.kanakku

import android.content.Context
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * App-lock PIN storage. The PIN itself is never written to disk —
 * only a salted, stretched hash:
 *
 *  - v1.0.4+ (format "v2"): PBKDF2-HMAC-SHA256, [PBKDF2_ITERATIONS]
 *    iterations, 16-byte SecureRandom salt (audit F7).
 *  - legacy (no format key): a single SHA-256 round. Such a hash
 *    still verifies ONCE, and the first successful verify
 *    transparently re-hashes the PIN to v2 — nobody is locked out
 *    by the upgrade.
 *
 * Failed attempts are counted HERE, natively, so every PIN prompt
 * (lock screen, balance reveal, Settings) shares one counter
 * (audit F1). After [MAX_FAILURES] consecutive failures, entry is
 * locked out for [lockoutSeconds] — 30 s, doubling per lockout,
 * capped at 15 min. The counter and the lockout deadline live in
 * these prefs, so killing the app does not reset them.
 */
object PinStore {
    private const val PREFS = "kanakku_pin"
    private const val KEY_HASH = "pin_hash"
    private const val KEY_SALT = "pin_salt"
    private const val KEY_FORMAT = "pin_hash_format"
    private const val FORMAT_PBKDF2 = "v2"
    private const val KEY_FAIL_COUNT = "pin_fail_count"
    private const val KEY_LOCKOUT_UNTIL = "pin_lockout_until"
    private const val KEY_LOCKOUT_COUNT = "pin_lockout_count"

    const val PBKDF2_ITERATIONS = 120_000
    const val MAX_FAILURES = 5
    const val BASE_LOCKOUT_SECONDS = 30L
    const val MAX_LOCKOUT_SECONDS = 900L

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isSet(context: Context): Boolean =
        prefs(context).getString(KEY_HASH, null) != null

    fun setPin(context: Context, pin: String) {
        val salt = ByteArray(16)
        SecureRandom().nextBytes(salt)
        val saltHex = salt.toHex()
        prefs(context).edit()
            .putString(KEY_SALT, saltHex)
            .putString(KEY_HASH, pbkdf2Hex(saltHex, pin))
            .putString(KEY_FORMAT, FORMAT_PBKDF2)
            .apply()
        resetFailures(context)
    }

    /**
     * Verifies WITHOUT touching the failure counter (the counted
     * entry point is [verifyCounted]). On a successful legacy-format
     * verify the stored hash is upgraded to PBKDF2.
     */
    fun verify(context: Context, pin: String): Boolean {
        val p = prefs(context)
        val stored = p.getString(KEY_HASH, null) ?: return false
        val salt = p.getString(KEY_SALT, null) ?: return false
        val legacy = p.getString(KEY_FORMAT, null) != FORMAT_PBKDF2
        val candidate = if (legacy) sha256Hex(salt, pin) else pbkdf2Hex(salt, pin)
        // Constant-time comparison — don't leak prefix matches.
        val ok = MessageDigest.isEqual(
            stored.toByteArray(Charsets.UTF_8),
            candidate.toByteArray(Charsets.UTF_8)
        )
        if (ok && legacy) {
            // Transparent upgrade: same salt, stretched hash.
            prefs(context).edit()
                .putString(KEY_HASH, pbkdf2Hex(salt, pin))
                .putString(KEY_FORMAT, FORMAT_PBKDF2)
                .apply()
        }
        return ok
    }

    // ---- failed-attempt accounting (audit F1) --------------------

    /** Lockout length for the [lockoutIndex]-th lockout (0-based):
     * 30 s doubling, capped at 15 min. Mirrored by the pure Dart
     * function pinLockoutSeconds() in app/lib/pin.dart. */
    fun lockoutSeconds(lockoutIndex: Int): Long {
        var s = BASE_LOCKOUT_SECONDS
        var i = 0
        while (i < lockoutIndex && s < MAX_LOCKOUT_SECONDS) {
            s = minOf(s * 2, MAX_LOCKOUT_SECONDS)
            i++
        }
        return s
    }

    /** Milliseconds of lockout remaining (0 when entry is allowed). */
    fun lockoutRemainingMillis(context: Context): Long {
        val until = prefs(context).getLong(KEY_LOCKOUT_UNTIL, 0L)
        return maxOf(0L, until - System.currentTimeMillis())
    }

    /**
     * The counted verify used by every PIN prompt (via the
     * "pinVerify" channel method). Returns (ok, lockoutSecondsLeft):
     * while a lockout is active the PIN is not even checked and the
     * remaining seconds come back; a failure that trips the threshold
     * starts the next lockout; a success clears all failure state.
     */
    fun verifyCounted(context: Context, pin: String): Pair<Boolean, Long> {
        val remaining = lockoutRemainingMillis(context)
        if (remaining > 0) return false to (remaining + 999) / 1000
        if (verify(context, pin)) {
            resetFailures(context)
            return true to 0L
        }
        val p = prefs(context)
        val failures = p.getInt(KEY_FAIL_COUNT, 0) + 1
        if (failures >= MAX_FAILURES) {
            val lockouts = p.getInt(KEY_LOCKOUT_COUNT, 0)
            val seconds = lockoutSeconds(lockouts)
            p.edit()
                .putInt(KEY_FAIL_COUNT, 0)
                .putInt(KEY_LOCKOUT_COUNT, lockouts + 1)
                .putLong(KEY_LOCKOUT_UNTIL, System.currentTimeMillis() + seconds * 1000)
                .apply()
            return false to seconds
        }
        p.edit().putInt(KEY_FAIL_COUNT, failures).apply()
        return false to 0L
    }

    private fun resetFailures(context: Context) {
        prefs(context).edit()
            .remove(KEY_FAIL_COUNT)
            .remove(KEY_LOCKOUT_UNTIL)
            .remove(KEY_LOCKOUT_COUNT)
            .apply()
    }

    /** Clears the PIN and all failure state (Settings → Disable,
     * after a successful unlock, and the danger-zone wipe). */
    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }

    private fun pbkdf2Hex(saltHex: String, pin: String): String {
        val spec = PBEKeySpec(
            pin.toCharArray(),
            saltHex.toByteArray(Charsets.UTF_8),
            PBKDF2_ITERATIONS,
            256
        )
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        return factory.generateSecret(spec).encoded.toHex()
    }

    /** Legacy v1 verifier (pre-v1.0.4 installs only). */
    private fun sha256Hex(saltHex: String, pin: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest("$saltHex:$pin".toByteArray(Charsets.UTF_8)).toHex()
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02x".format(it) }
}
