package `in`.kanakku.kanakku

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * At-rest encryption for the CaptureStore documents (v1.0.4, audit
 * F3). Values are AES-256-GCM encrypted with a key held in the
 * Android Keystore; the key is NOT bound to user authentication, so
 * background components (SMS receiver, notification listener, boot
 * receiver) keep working while the phone is locked.
 *
 * Wire format: "enc:v1:" + Base64( IV(12) || ciphertext+tag ).
 * Values without the marker are legacy plaintext from before v1.0.4 —
 * [decrypt] returns them unchanged and the store rewrites them
 * encrypted on the next write (transparent migration).
 *
 * Failure policy: encryption is best-effort. If the Keystore is
 * unavailable the plaintext is stored rather than losing the user's
 * data; if a marked value cannot be decrypted (key lost), the value
 * is treated as unreadable and [decrypt] returns the fallback the
 * caller passes (usually the empty default).
 */
object StoreCrypto {
    private const val MARKER = "enc:v1:"
    private const val KEY_ALIAS = "kanakku_store_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    fun isEncrypted(stored: String?): Boolean =
        stored != null && stored.startsWith(MARKER)

    fun encrypt(plain: String): String {
        if (plain.startsWith(MARKER)) return plain // never double-wrap
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val iv = cipher.iv
            val ct = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
            MARKER + Base64.encodeToString(iv + ct, Base64.NO_WRAP)
        } catch (e: Exception) {
            plain
        }
    }

    fun decrypt(stored: String, fallback: String): String {
        if (!isEncrypted(stored)) return stored // legacy plaintext
        return try {
            val raw = Base64.decode(stored.substring(MARKER.length), Base64.NO_WRAP)
            if (raw.size <= IV_BYTES) return fallback
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE, key(),
                GCMParameterSpec(TAG_BITS, raw.copyOfRange(0, IV_BYTES))
            )
            String(
                cipher.doFinal(raw.copyOfRange(IV_BYTES, raw.size)),
                Charsets.UTF_8
            )
        } catch (e: Exception) {
            fallback
        }
    }
}
