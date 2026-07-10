package com.personalintelligence.whatsappexporter

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.ContactsContract
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val CONTACTS_CHANNEL = "wa_group_extractor/contacts"
        private const val ACCESSIBILITY_CHANNEL = "wa_group_extractor/accessibility"
        private const val FILES_CHANNEL = "wa_group_extractor/files"
        private const val NETWORK_CHANNEL = "wa_group_extractor/network"
        private const val CONTACTS_PERMISSION_REQUEST = 4201
    }

    private var pendingContactsResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTACTS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "contactsPermissionGranted" -> result.success(hasContactsPermission())
                    "requestContactsPermission" -> requestContactsPermission(result)
                    "importLocalContacts" -> {
                        if (!hasContactsPermission()) {
                            result.error("permission_denied", "READ_CONTACTS is not granted.", null)
                        } else {
                            result.success(readLocalContacts())
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ACCESSIBILITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "accessibilityEnabled" -> result.success(isAccessibilityServiceEnabled())
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(null)
                    }
                    "openWhatsApp" -> openWhatsApp(result)
                    "latestCapture" -> {
                        val capture = getSharedPreferences(
                            WhatsAppCaptureAccessibilityService.PREFS_NAME,
                            MODE_PRIVATE,
                        ).getString(WhatsAppCaptureAccessibilityService.KEY_LATEST_CAPTURE_JSON, null)
                        result.success(capture)
                    }
                    "clearLatestCapture" -> {
                        getSharedPreferences(
                            WhatsAppCaptureAccessibilityService.PREFS_NAME,
                            MODE_PRIVATE,
                        ).edit().remove(
                            WhatsAppCaptureAccessibilityService.KEY_LATEST_CAPTURE_JSON,
                        ).apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copyToDownloads" -> copyToDownloads(
                        sourcePath = call.argument("sourcePath"),
                        displayName = call.argument("displayName"),
                        mimeType = call.argument("mimeType"),
                        result = result,
                    )
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkWhatsAppWeb" -> checkWhatsAppWeb(result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CONTACTS_PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingContactsResult?.success(granted)
            pendingContactsResult = null
        }
    }

    private fun hasContactsPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestContactsPermission(result: MethodChannel.Result) {
        if (hasContactsPermission()) {
            result.success(true)
            return
        }
        if (pendingContactsResult != null) {
            result.error("request_in_progress", "A contacts permission request is already active.", null)
            return
        }
        pendingContactsResult = result
        requestPermissions(
            arrayOf(Manifest.permission.READ_CONTACTS),
            CONTACTS_PERMISSION_REQUEST,
        )
    }

    private fun readLocalContacts(): List<Map<String, Any>> {
        val emailsByContactId = linkedMapOf<String, MutableSet<String>>()
        val namesByContactId = linkedMapOf<String, String>()

        contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Email.CONTACT_ID,
                ContactsContract.CommonDataKinds.Email.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Email.ADDRESS,
            ),
            null,
            null,
            ContactsContract.CommonDataKinds.Email.DISPLAY_NAME + " COLLATE NOCASE ASC",
        )?.use { cursor ->
            val contactIdIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Email.CONTACT_ID,
            )
            val nameIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Email.DISPLAY_NAME,
            )
            val emailIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Email.ADDRESS,
            )
            while (cursor.moveToNext()) {
                val contactId = cursor.getString(contactIdIndex) ?: continue
                val name = cursor.getString(nameIndex).orEmpty()
                val email = cursor.getString(emailIndex).orEmpty()
                if (email.isBlank()) {
                    continue
                }
                namesByContactId.putIfAbsent(contactId, name)
                emailsByContactId.getOrPut(contactId) { linkedSetOf() }.add(email)
            }
        }

        val output = linkedMapOf<String, Map<String, Any>>()
        contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.NORMALIZED_NUMBER,
            ),
            null,
            null,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " COLLATE NOCASE ASC",
        )?.use { cursor ->
            val contactIdIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            )
            val nameIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            )
            val phoneIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )
            val normalizedIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.NORMALIZED_NUMBER,
            )
            while (cursor.moveToNext()) {
                val contactId = cursor.getString(contactIdIndex) ?: continue
                val name = cursor.getString(nameIndex).orEmpty()
                val phone = cursor.getString(phoneIndex).orEmpty()
                val normalized = cursor.getString(normalizedIndex).orEmpty()
                    .ifBlank { normalizePhone(phone) }
                if (phone.isBlank()) {
                    continue
                }
                val key = "phone:$normalized:${name.lowercase(Locale.US)}"
                output[key] = mapOf(
                    "id" to safeId("android_contact", "$contactId:$normalized"),
                    "name" to name,
                    "phone" to phone,
                    "normalized_phone" to normalized,
                    "email" to (emailsByContactId[contactId]?.firstOrNull().orEmpty()),
                    "source" to "android_contacts",
                )
                namesByContactId.putIfAbsent(contactId, name)
            }
        }

        for ((contactId, emails) in emailsByContactId) {
            val name = namesByContactId[contactId].orEmpty()
            for (email in emails) {
                val key = "email:${email.lowercase(Locale.US)}"
                output.putIfAbsent(
                    key,
                    mapOf(
                        "id" to safeId("android_email_contact", "$contactId:$email"),
                        "name" to name.ifBlank { email },
                        "phone" to "",
                        "normalized_phone" to "",
                        "email" to email,
                        "source" to "android_contacts",
                    ),
                )
            }
        }
        return output.values.toList()
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ).orEmpty()
        val expected = "$packageName/${WhatsAppCaptureAccessibilityService::class.java.name}"
        return enabledServices.split(':').any { service ->
            service.equals(expected, ignoreCase = true) ||
                (service.startsWith(packageName, ignoreCase = true) &&
                    service.contains("WhatsAppCaptureAccessibilityService", ignoreCase = true))
        }
    }

    private fun openWhatsApp(result: MethodChannel.Result) {
        val launchIntent = packageManager.getLaunchIntentForPackage("com.whatsapp")
            ?: packageManager.getLaunchIntentForPackage("com.whatsapp.w4b")
        if (launchIntent == null) {
            result.error("whatsapp_missing", "WhatsApp is not installed.", null)
            return
        }
        startActivity(launchIntent)
        result.success(null)
    }

    private fun copyToDownloads(
        sourcePath: String?,
        displayName: String?,
        mimeType: String?,
        result: MethodChannel.Result,
    ) {
        if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
            result.error("invalid_args", "sourcePath and displayName are required.", null)
            return
        }
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            result.error("missing_file", "Export file does not exist.", sourcePath)
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType ?: "application/octet-stream")
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: throw IllegalStateException("Could not create Downloads entry.")
                contentResolver.openOutputStream(uri)?.use { output ->
                    FileInputStream(sourceFile).use { input -> input.copyTo(output) }
                } ?: throw IllegalStateException("Could not open Downloads output stream.")
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                result.success(uri.toString())
            } else {
                @Suppress("DEPRECATION")
                val downloads = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS,
                )
                downloads.mkdirs()
                val target = File(downloads, displayName)
                sourceFile.copyTo(target, overwrite = true)
                result.success(target.absolutePath)
            }
        } catch (error: Throwable) {
            result.error("copy_failed", error.message, null)
        }
    }

    private fun checkWhatsAppWeb(result: MethodChannel.Result) {
        Thread {
            val host = "web.whatsapp.com"
            val output = linkedMapOf<String, Any>(
                "host" to host,
                "dns_ok" to false,
                "https_ok" to false,
                "addresses" to emptyList<String>(),
                "status_code" to -1,
                "error" to "",
            )

            try {
                val addresses = InetAddress.getAllByName(host)
                    .mapNotNull { address -> address.hostAddress }
                    .distinct()
                output["dns_ok"] = addresses.isNotEmpty()
                output["addresses"] = addresses
            } catch (error: Throwable) {
                output["error"] = "DNS failed: ${error.message.orEmpty()}"
            }

            try {
                val connection = (URL("https://$host/").openConnection() as HttpURLConnection)
                connection.requestMethod = "GET"
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                connection.instanceFollowRedirects = false
                connection.setRequestProperty(
                    "User-Agent",
                    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
                        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
                )
                val code = connection.responseCode
                output["status_code"] = code
                output["https_ok"] = code in 200..399 || code == 403
                connection.disconnect()
            } catch (error: Throwable) {
                val existing = output["error"].toString()
                output["error"] = listOf(existing, "HTTPS failed: ${error.message.orEmpty()}")
                    .filter { it.isNotBlank() }
                    .joinToString("; ")
            }

            runOnUiThread {
                result.success(output)
            }
        }.start()
    }

    private fun normalizePhone(input: String): String {
        val trimmed = input.trim()
        val digits = trimmed.filter { it.isDigit() }
        if (digits.length < 6) {
            return ""
        }
        if (trimmed.startsWith("+")) {
            return "+$digits"
        }
        if (digits.startsWith("00") && digits.length > 8) {
            return "+${digits.substring(2)}"
        }
        return digits
    }

    private fun safeId(prefix: String, value: String): String {
        val safe = value.lowercase(Locale.US)
            .replace(Regex("[^a-z0-9]+"), "_")
            .trim('_')
            .take(80)
        return "${prefix}_${safe}_${value.hashCode().toString().replace("-", "n")}"
    }
}
