package `in`.kanakku.kanakku

import android.Manifest
import android.app.KeyguardManager
import android.content.DialogInterface
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.hardware.fingerprint.FingerprintManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Base64
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import java.io.ByteArrayOutputStream
import java.io.File
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "in.kanakku/capture"
    private val smsPermissionRequest = 7001
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // v1.0.4 (audit F8): balances must not leak through the
        // recents thumbnail, screenshots or screen recording.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        // v1.0.4 (audit F2): one-time purge of the pre-filter SMS /
        // notification archive (also runs before the first append).
        CaptureStore.runV104Migrations(this)
        // v1.1 (spec §6.1): seed the recurring + alert-state
        // documents on first launch of the new version.
        CaptureStore.runV110Migrations(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasSmsPermission" -> result.success(hasSmsPermission())
                    "requestSmsPermission" -> requestSmsPermission(result)
                    "readSmsInbox" -> {
                        val limit = call.argument<Int>("limit") ?: 300
                        result.success(readSmsInbox(limit))
                    }
                    "getCapturedSms" -> result.success(CaptureStore.sms(this))
                    "getCapturedNotifications" -> result.success(CaptureStore.notifications(this))
                    "getManual" -> result.success(CaptureStore.manual(this))
                    "setManual" -> {
                        val json = call.argument<String>("json") ?: "[]"
                        Thread {
                            val saved = runCatching { CaptureStore.setManual(this@MainActivity, json) }
                                .getOrDefault(false)
                            runOnUiThread { result.success(saved) }
                        }.start()
                    }
                    "getRemoved" -> result.success(CaptureStore.removed(this))
                    "setRemoved" -> {
                        CaptureStore.setRemoved(this, call.argument<String>("json") ?: "[]")
                        result.success(true)
                    }
                    "shareCsv" -> {
                        val filename = call.argument<String>("filename") ?: "kanakku-export.csv"
                        val content = call.argument<String>("content") ?: ""
                        result.success(shareCsv(filename, content))
                    }
                    "getSplits" -> result.success(CaptureStore.splits(this))
                    "setSplits" -> {
                        CaptureStore.setSplits(this, call.argument<String>("json") ?: "[]")
                        result.success(true)
                    }
                    "getBudgets" -> result.success(CaptureStore.budgets(this))
                    "setBudgets" -> {
                        CaptureStore.setBudgets(this, call.argument<String>("json") ?: "{}")
                        result.success(true)
                    }
                    "getStatement" -> result.success(CaptureStore.statement(this))
                    "setStatement" -> {
                        CaptureStore.setStatement(this, call.argument<String>("json") ?: "[]")
                        result.success(true)
                    }
                    "pickFile" -> pickStatementFile(result)
                    "shareBytes" -> {
                        val filename = call.argument<String>("filename") ?: "kanakku-export.pdf"
                        val mime = call.argument<String>("mime") ?: "application/pdf"
                        val data = call.argument<String>("data") ?: ""
                        result.success(shareBytes(filename, mime, data))
                    }
                    "setDailySummary" -> {
                        val text = call.argument<String>("text") ?: ""
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val hour = call.argument<Int>("hour") ?: 21
                        val minute = call.argument<Int>("minute") ?: 0
                        CaptureStore.setSummaryText(this, text)
                        CaptureStore.setSummaryOn(this, enabled)
                        CaptureStore.setSummaryTime(this, hour, minute)
                        if (enabled) SummaryNotifier.arm(this) else SummaryNotifier.disarm(this)
                        result.success(true)
                    }
                    "getSettings" -> result.success(CaptureStore.settings(this))
                    "setSettings" -> {
                        CaptureStore.setSettings(this, call.argument<String>("json") ?: "{}")
                        result.success(true)
                    }
                    "getCategories" -> result.success(CaptureStore.categories(this))
                    "setCategories" -> {
                        CaptureStore.setCategories(this, call.argument<String>("json") ?: "{}")
                        result.success(true)
                    }
                    "getRecurring" -> result.success(CaptureStore.recurring(this))
                    "setRecurring" -> {
                        // Commit write like setManual (spec §2.5).
                        val json = call.argument<String>("json") ?: ""
                        Thread {
                            val saved = runCatching { CaptureStore.setRecurring(this@MainActivity, json) }
                                .getOrDefault(false)
                            runOnUiThread { result.success(saved) }
                        }.start()
                    }
                    "getAlertState" -> result.success(CaptureStore.alertState(this))
                    "setAlertState" -> {
                        CaptureStore.setAlertState(this, call.argument<String>("json") ?: "{}")
                        result.success(true)
                    }
                    "postBudgetAlert" -> {
                        val title = call.argument<String>("title") ?: "Budget alert"
                        val body = call.argument<String>("body") ?: ""
                        result.success(BudgetNotifier.post(this, title, body))
                    }
                    "biometricStatus" -> result.success(biometricStatus())
                    "biometricPrompt" -> {
                        val title = call.argument<String>("title") ?: "Unlock Kanakku"
                        val subtitle = call.argument<String>("subtitle") ?: "Use fingerprint or face"
                        biometricPrompt(title, subtitle, result)
                    }
                    "wipeAll" -> {
                        SummaryNotifier.disarm(this)
                        CaptureStore.clearAll(this)
                        PinStore.clear(this)
                        result.success(true)
                    }
                    "openMail" -> {
                        val to = call.argument<String>("to") ?: ""
                        result.success(openMail(to))
                    }
                    "postSummaryNow" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (text.isNotBlank()) CaptureStore.setSummaryText(this, text)
                        result.success(SummaryNotifier.postStored(this))
                    }
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "pinIsSet" -> result.success(PinStore.isSet(this))
                    "pinSet" -> {
                        val pin = call.argument<String>("pin") ?: ""
                        if (pin.isEmpty()) {
                            result.success(false)
                        } else {
                            // PBKDF2 is deliberately slow — keep it
                            // off the platform thread.
                            Thread {
                                PinStore.setPin(this@MainActivity, pin)
                                runOnUiThread { result.success(true) }
                            }.start()
                        }
                    }
                    "pinVerify" -> {
                        // v1.0.4 (audit F1): the ONE counted verify
                        // path — every PIN prompt (lock screen,
                        // balance reveal, Settings) funnels through
                        // here, so attempts and backoff are shared.
                        // Returns {ok, lockoutSeconds}.
                        val pin = call.argument<String>("pin") ?: ""
                        Thread {
                            val answer = if (pin.isEmpty()) {
                                false to (PinStore.lockoutRemainingMillis(this@MainActivity) + 999) / 1000
                            } else {
                                PinStore.verifyCounted(this@MainActivity, pin)
                            }
                            runOnUiThread {
                                result.success(
                                    mapOf(
                                        "ok" to answer.first,
                                        "lockoutSeconds" to answer.second
                                    )
                                )
                            }
                        }.start()
                    }
                    "pinLockout" -> result.success(
                        (PinStore.lockoutRemainingMillis(this) + 999) / 1000
                    )
                    "pinClear" -> {
                        PinStore.clear(this)
                        result.success(true)
                    }
                    "encryptBackup" -> {
                        // v1.0.4 (audit F5): passphrase-encrypted
                        // backup blob (PBKDF2 + AES-GCM, native).
                        val pass = call.argument<String>("passphrase") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        Thread {
                            val blob = BackupCrypto.encrypt(pass, text)
                            runOnUiThread { result.success(blob) }
                        }.start()
                    }
                    "decryptBackup" -> {
                        val pass = call.argument<String>("passphrase") ?: ""
                        val data = call.argument<String>("data") ?: ""
                        Thread {
                            // null = wrong passphrase / bad blob.
                            val plain = BackupCrypto.decrypt(pass, data)
                            runOnUiThread { result.success(plain) }
                        }.start()
                    }
                    "isNotificationAccessEnabled" -> result.success(isNotificationAccessEnabled())
                    "openNotificationSettings" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private val notifPermissionRequest = 7002
    private var pendingNotifResult: MethodChannel.Result? = null

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingNotifResult = result
        ActivityCompat.requestPermissions(
            this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), notifPermissionRequest
        )
    }

    private fun hasSmsPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestSmsPermission(result: MethodChannel.Result) {
        if (hasSmsPermission()) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS),
            smsPermissionRequest
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == smsPermissionRequest) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
        if (requestCode == notifPermissionRequest) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingNotifResult?.success(granted)
            pendingNotifResult = null
        }
    }

    // ---- Bank-statement file picker (v0.7) -------------------------
    // ACTION_OPEN_DOCUMENT — no storage permission and no third-party
    // file-picker dependency. The picked file's bytes come back over
    // the channel; Dart does the CSV parsing. Cap: 5 MB.

    private val pickFileRequest = 7003
    private var pendingPickResult: MethodChannel.Result? = null

    private companion object {
        const val MAX_PICK_BYTES = 5 * 1024 * 1024
    }

    private fun pickStatementFile(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.success(null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "text/csv",
                    "text/comma-separated-values",
                    "text/plain",
                    "application/pdf"
                )
            )
        }
        try {
            startActivityForResult(intent, pickFileRequest)
        } catch (e: Exception) {
            pendingPickResult = null
            result.success(null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickFileRequest) return
        val result = pendingPickResult ?: return
        pendingPickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null) // user cancelled
            return
        }
        // v1.0.4 (audit F10): read on a background thread and enforce
        // the 5 MB cap WHILE streaming — the old code buffered the
        // whole file in RAM on the main thread before checking.
        Thread {
            val answer: Map<String, Any?> = try {
                val mime = contentResolver.getType(uri) ?: ""
                var name = ""
                var declaredSize = -1L
                contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null, null, null
                )?.use { c ->
                    if (c.moveToFirst()) {
                        name = c.getString(0) ?: ""
                        val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeIdx >= 0 && !c.isNull(sizeIdx)) {
                            declaredSize = c.getLong(sizeIdx)
                        }
                    }
                }
                when {
                    declaredSize > MAX_PICK_BYTES -> mapOf(
                        "name" to name, "mime" to mime, "error" to "too_large"
                    )
                    else -> {
                        val bytes = readCapped(uri, MAX_PICK_BYTES)
                        when (bytes) {
                            null -> mapOf(
                                "name" to name, "mime" to mime,
                                "error" to "unreadable"
                            )
                            CAPPED -> mapOf(
                                "name" to name, "mime" to mime,
                                "error" to "too_large"
                            )
                            else -> mapOf(
                                "name" to name, "mime" to mime, "data" to bytes
                            )
                        }
                    }
                }
            } catch (e: Exception) {
                mapOf("name" to "", "mime" to "", "error" to "failed")
            }
            runOnUiThread { result.success(answer) }
        }.start()
    }

    /** Sentinel for "stream exceeded the cap" (identity-compared). */
    private val CAPPED = ByteArray(0)

    /** Streams [uri] fully into memory, aborting as soon as more
     * than [max] bytes arrive — the file is never buffered beyond
     * the cap. Returns null when the stream cannot be opened. */
    private fun readCapped(uri: Uri, max: Int): ByteArray? {
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use {
            val out = ByteArrayOutputStream()
            val buf = ByteArray(64 * 1024)
            var total = 0
            while (true) {
                val n = it.read(buf)
                if (n < 0) break
                total += n
                if (total > max) return CAPPED
                out.write(buf, 0, n)
            }
            return out.toByteArray()
        }
    }

    private fun readSmsInbox(limit: Int): List<Map<String, Any>> {
        if (!hasSmsPermission()) return emptyList()
        val out = mutableListOf<Map<String, Any>>()
        val uri = Uri.parse("content://sms/inbox")
        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(
                uri,
                arrayOf("address", "body", "date"),
                null, null, "date DESC"
            )
            if (cursor != null) {
                val addrIdx = cursor.getColumnIndex("address")
                val bodyIdx = cursor.getColumnIndex("body")
                val dateIdx = cursor.getColumnIndex("date")
                while (cursor.moveToNext() && out.size < limit) {
                    out.add(mapOf(
                        "sender" to (cursor.getString(addrIdx) ?: ""),
                        "body" to (cursor.getString(bodyIdx) ?: ""),
                        "ts" to cursor.getLong(dateIdx)
                    ))
                }
            }
        } catch (e: Exception) {
            // Permission race or provider unavailable — return what we have.
        } finally {
            cursor?.close()
        }
        return out
    }

    /**
     * CSV export: write the file into the app cache, then open the
     * Android share sheet so it can go to WhatsApp / Drive / mail.
     * Returns the saved file's absolute path, or "" on any failure
     * (Dart then falls back to telling the user inline).
     */
    /** The exports cache, pruned of anything older than 24 h
     * (v1.0.4, audit F14 — shared copies of the full-history backup
     * must not accumulate here forever). */
    private fun exportsDir(): File {
        val dir = File(cacheDir, "exports")
        if (!dir.exists()) dir.mkdirs()
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        try {
            dir.listFiles()?.forEach { f ->
                if (f.lastModified() < cutoff) f.delete()
            }
        } catch (e: Exception) {
            // Pruning is defence-in-depth; never block a share on it.
        }
        return dir
    }

    private fun shareCsv(filename: String, content: String): String {
        return try {
            val dir = exportsDir()
            val file = File(dir, filename)
            file.writeText(content)
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "Kanakku transactions export")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Share Kanakku export"))
            file.absolutePath
        } catch (e: Exception) {
            ""
        }
    }

    /**
     * Binary share (PDF export, v0.5): same FileProvider path as the
     * CSV share, but the Dart side sends Base64 bytes + a MIME type.
     * Returns the saved file's absolute path, or "" on failure.
     */
    private fun shareBytes(filename: String, mime: String, base64: String): String {
        return try {
            val bytes = Base64.decode(base64, Base64.DEFAULT)
            val dir = exportsDir()
            val file = File(dir, filename)
            file.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "Kanakku transactions export")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Share Kanakku export"))
            file.absolutePath
        } catch (e: Exception) {
            ""
        }
    }

    /** Support contact (v1.0): ACTION_SENDTO with a mailto: URI so
     * only mail apps answer. False when none is installed. */
    private fun openMail(to: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_SENDTO).apply {
                data = Uri.parse("mailto:$to")
                putExtra(Intent.EXTRA_SUBJECT, "Kanakku — query / feedback")
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun isNotificationAccessEnabled(): Boolean {
        val flat = Settings.Secure.getString(
            contentResolver, "enabled_notification_listeners"
        ) ?: return false
        return flat.contains(packageName)
    }

    // ---- Biometric unlock (v1.1, final_spec §5) ---------------------
    // Framework android.hardware.biometrics only — no AndroidX, no
    // new dependencies (test T-X4). API 24–27 are PIN-only by
    // decision: the prompt exists from API 28, and no
    // device-credential fallback is offered in v1.1.

    /** Probe: exactly one of available | noneEnrolled | noHardware
     *  | noDeviceLock | unsupportedApi (spec §5.2). */
    @Suppress("DEPRECATION")
    private fun biometricStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return "unsupportedApi"
        val kg = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
        if (!kg.isDeviceSecure) return "noDeviceLock"
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Framework API: no BiometricManager.from() (that is
            // the AndroidX name) — the system service is the way.
            val bm = getSystemService(BiometricManager::class.java)
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            } else {
                bm.canAuthenticate()
            }
            when (code) {
                BiometricManager.BIOMETRIC_SUCCESS -> "available"
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "noneEnrolled"
                BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "noHardware"
                else -> "noHardware"
            }
        } else {
            // API 28: FingerprintManager is the only probe surface.
            val fm = getSystemService(FINGERPRINT_SERVICE) as? FingerprintManager
            when {
                fm == null || !fm.isHardwareDetected -> "noHardware"
                !fm.hasEnrolledFingerprints() -> "noneEnrolled"
                else -> "available"
            }
        }
    }

    private var pendingBiometricResult: MethodChannel.Result? = null

    /** Shows the framework prompt. The channel result is true ONLY
     * on a real authentication success: cancel, the negative
     * button, lockout and every other error complete false
     * (fail-closed, audit F13). */
    private fun biometricPrompt(title: String, subtitle: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            result.success(false)
            return
        }
        if (pendingBiometricResult != null) {
            result.success(false)
            return
        }
        pendingBiometricResult = result
        val executor = mainExecutor
        try {
            val prompt = BiometricPrompt.Builder(this)
                .setTitle(title)
                .setSubtitle(subtitle)
                // Framework name (setNegativeButtonText is AndroidX).
                .setNegativeButton("Use PIN", executor,
                    DialogInterface.OnClickListener { _, _ -> finishBiometric(false) })
                .build()
            prompt.authenticate(
                CancellationSignal(), executor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        r: BiometricPrompt.AuthenticationResult?
                    ) {
                        finishBiometric(true)
                    }

                    override fun onAuthenticationError(
                        errorCode: Int, errString: CharSequence?
                    ) {
                        // Includes ERROR_USER_CANCELED, the negative
                        // button and ERROR_LOCKOUT(_PERMANENT):
                        // all fall back to the PIN pad (spec §5.2).
                        finishBiometric(false)
                    }

                    override fun onAuthenticationFailed() {
                        // A single non-match: the system prompt
                        // stays open; nothing to report yet.
                    }
                }
            )
        } catch (e: Exception) {
            finishBiometric(false)
        }
    }

    private fun finishBiometric(ok: Boolean) {
        val r = pendingBiometricResult ?: return
        pendingBiometricResult = null
        runOnUiThread { r.success(ok) }
    }
}
