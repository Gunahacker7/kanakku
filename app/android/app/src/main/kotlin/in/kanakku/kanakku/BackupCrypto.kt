package `in`.kanakku.kanakku

import android.util.Base64
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Passphrase encryption for backup files (v1.0.4, audit F5). The key
 * is derived from the user's passphrase with PBKDF2-HMAC-SHA256
 * (120,000 iterations) and the backup JSON is AES-256-GCM encrypted.
 *
 * Blob format (single Base64 string, carried in the backup envelope's
 * "data" field): salt(16) || iv(12) || ciphertext+tag.
 *
 * A wrong passphrase fails the GCM tag check and [decrypt] returns
 * null — there is no partial plaintext and no oracle beyond that.
 */
object BackupCrypto {
    private const val ITERATIONS = 120_000
    private const val SALT_BYTES = 16
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128
    private const val KEY_BITS = 256
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    private fun deriveKey(passphrase: String, salt: ByteArray): SecretKeySpec {
        val spec = PBEKeySpec(
            passphrase.toCharArray(), salt, ITERATIONS, KEY_BITS
        )
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        return SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
    }

    /** Returns the Base64 blob, or null when encryption fails. */
    fun encrypt(passphrase: String, plaintext: String): String? {
        if (passphrase.isEmpty() || plaintext.isEmpty()) return null
        return try {
            val random = SecureRandom()
            val salt = ByteArray(SALT_BYTES).also { random.nextBytes(it) }
            val iv = ByteArray(IV_BYTES).also { random.nextBytes(it) }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.ENCRYPT_MODE, deriveKey(passphrase, salt),
                GCMParameterSpec(TAG_BITS, iv)
            )
            val ct = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
            Base64.encodeToString(salt + iv + ct, Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
    }

    /** Returns the plaintext, or null for a wrong passphrase / a
     * malformed or tampered blob. */
    fun decrypt(passphrase: String, blobB64: String): String? {
        if (passphrase.isEmpty() || blobB64.isEmpty()) return null
        return try {
            val raw = Base64.decode(blobB64, Base64.NO_WRAP)
            if (raw.size <= SALT_BYTES + IV_BYTES) return null
            val salt = raw.copyOfRange(0, SALT_BYTES)
            val iv = raw.copyOfRange(SALT_BYTES, SALT_BYTES + IV_BYTES)
            val ct = raw.copyOfRange(SALT_BYTES + IV_BYTES, raw.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE, deriveKey(passphrase, salt),
                GCMParameterSpec(TAG_BITS, iv)
            )
            String(cipher.doFinal(ct), Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }
}
