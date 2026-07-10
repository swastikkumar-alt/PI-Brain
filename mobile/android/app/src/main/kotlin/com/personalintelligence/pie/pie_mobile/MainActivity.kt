package com.personalintelligence.pie.pie_mobile

import android.app.role.RoleManager
import android.content.ContentUris
import android.Manifest
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Telephony
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import androidx.core.content.FileProvider
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URLEncoder
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {
    private val notificationChannelName = "pie_mobile/notifications"
    private val voiceChannelName = "pie_mobile/voice"
    private val contactsChannelName = "pie_mobile/contacts"
    private val accessibilityChannelName = "pie_mobile/accessibility"
    private val connectorsChannelName = "pie_mobile/connectors"
    private val nativeDatasourcesChannelName = "pie_mobile/native_datasources"
    private val appsChannelName = "pie_mobile/apps"

    private var notificationChannel: MethodChannel? = null
    private var voiceChannel: MethodChannel? = null
    private var connectorsChannel: MethodChannel? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var textToSpeechReady = false
    private var receiversRegistered = false
    private val nativeScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val healthConnectPackage = "com.google.android.apps.healthdata"
    private val healthPermissions = setOf(
        HealthPermission.getReadPermission(StepsRecord::class),
        HealthPermission.getReadPermission(SleepSessionRecord::class),
    )

    private val notificationReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val packageName = intent.getStringExtra("packageName") ?: ""
            val title = intent.getStringExtra("title") ?: ""
            val text = intent.getStringExtra("text") ?: ""

            notificationChannel?.invokeMethod(
                "onNotification",
                mapOf(
                    "packageName" to packageName,
                    "title" to title,
                    "text" to text,
                ),
            )
        }
    }

    private val connectorReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            connectorsChannel?.invokeMethod(
                "onConnectorEvent",
                mapOf(
                    "actionId" to (intent.getStringExtra("actionId") ?: ""),
                    "status" to (intent.getStringExtra("status") ?: "failed"),
                    "message" to (intent.getStringExtra("message") ?: ""),
                ),
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        notificationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            notificationChannelName,
        )
        voiceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            voiceChannelName,
        )
        val contactsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            contactsChannelName,
        )
        val accessibilityChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            accessibilityChannelName,
        )
        connectorsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            connectorsChannelName,
        )
        val nativeDatasourcesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            nativeDatasourcesChannelName,
        )
        val appsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appsChannelName,
        )
        configureNotificationChannel()
        configureVoiceChannel()
        configureContactsChannel(contactsChannel)
        configureAccessibilityChannel(accessibilityChannel)
        configureConnectorsChannel()
        configureNativeDatasourcesChannel(nativeDatasourcesChannel)
        configureAppsChannel(appsChannel)
        registerAppReceivers()
        initializeTextToSpeech()
    }

    private fun configureNotificationChannel() {
        notificationChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermission" -> {
                    val enabledListeners = Settings.Secure.getString(
                        contentResolver,
                        "enabled_notification_listeners",
                    )
                    val isGranted = enabledListeners?.contains(packageName) == true
                    result.success(isGranted)
                }

                "requestPermission" -> {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(true)
                }

                "isGmailInstalled" -> result.success(isPackageInstalled("com.google.android.gm"))
                "isWhatsAppInstalled" -> result.success(getWhatsAppPackage() != null)

                else -> result.notImplemented()
            }
        }
    }

    private fun configureVoiceChannel() {
        voiceChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermission" -> result.success(
                    hasPermission(Manifest.permission.RECORD_AUDIO),
                )

                "requestPermission" -> {
                    requestRuntimePermission(Manifest.permission.RECORD_AUDIO, 1001)
                    result.success(true)
                }

                "startListening" -> startListening(result)
                "stopListening" -> {
                    speechRecognizer?.stopListening()
                    result.success(true)
                }

                "speak" -> {
                    val text = call.argument<String>("text") ?: ""
                    speak(text)
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun configureContactsChannel(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermission" -> result.success(
                    hasPermission(Manifest.permission.READ_CONTACTS),
                )

                "requestPermission" -> {
                    requestRuntimePermission(Manifest.permission.READ_CONTACTS, 1002)
                    result.success(true)
                }

                "searchContacts" -> {
                    if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
                        result.success(emptyList<Map<String, String>>())
                        return@setMethodCallHandler
                    }
                    val query = call.argument<String>("query") ?: ""
                    result.success(searchContacts(query))
                }

                "listPhoneContacts" -> {
                    if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
                        result.success(emptyList<Map<String, String>>())
                        return@setMethodCallHandler
                    }
                    val limit = call.argument<Int>("limit") ?: 750
                    result.success(listPhoneContacts(limit))
                }

                "searchEmailContacts" -> {
                    if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
                        result.success(emptyList<Map<String, String>>())
                        return@setMethodCallHandler
                    }
                    val query = call.argument<String>("query") ?: ""
                    result.success(searchEmailContacts(query))
                }

                "listEmailContacts" -> {
                    if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
                        result.success(emptyList<Map<String, String>>())
                        return@setMethodCallHandler
                    }
                    val limit = call.argument<Int>("limit") ?: 750
                    result.success(listEmailContacts(limit))
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun configureAccessibilityChannel(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(isPieAccessibilityEnabled())
                "openSettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun configureConnectorsChannel() {
        connectorsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isWhatsAppInstalled" -> result.success(isPackageInstalled("com.whatsapp"))
                "isEmailAvailable" -> result.success(isEmailAvailable())
                "sendWhatsAppMessage" -> {
                    val actionId = call.argument<String>("actionId") ?: ""
                    val recipientName = call.argument<String>("recipientName") ?: ""
                    val phoneNumber = call.argument<String>("phoneNumber") ?: ""
                    val message = call.argument<String>("message") ?: ""
                    val unlockPolicy = call.argument<String>("unlockPolicy") ?: "unlockEachTime"
                    result.success(
                        startWhatsAppMessage(
                            actionId = actionId,
                            recipientName = recipientName,
                            phoneNumber = phoneNumber,
                            message = message,
                            unlockPolicy = unlockPolicy,
                        ),
                    )
                }
                "composeEmail" -> {
                    val emailAddress = call.argument<String>("emailAddress") ?: ""
                    val subject = call.argument<String>("subject") ?: "Update"
                    val body = call.argument<String>("body") ?: ""
                    val attachmentPaths =
                        call.argument<List<String>>("attachmentPaths") ?: emptyList()
                    result.success(composeEmail(emailAddress, subject, body, attachmentPaths))
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun configureNativeDatasourcesChannel(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkSmsPermission" -> result.success(
                    hasPermission(Manifest.permission.READ_SMS),
                )

                "requestSmsPermission" -> {
                    requestRuntimePermission(Manifest.permission.READ_SMS, 1003)
                    result.success(true)
                }

                "checkSmsManagementCapability" -> result.success(isDefaultSmsApp())

                "requestDefaultSmsRole" -> {
                    requestDefaultSmsRole()
                    result.success(true)
                }

                "deleteSmsById" -> {
                    val id = call.argument<String>("id") ?: ""
                    result.success(deleteSmsById(id))
                }

                "checkCallLogPermission" -> result.success(
                    hasPermission(Manifest.permission.READ_CALL_LOG),
                )

                "requestCallLogPermission" -> {
                    requestRuntimePermission(Manifest.permission.READ_CALL_LOG, 1004)
                    result.success(true)
                }

                "readRecentSms" -> {
                    if (!hasPermission(Manifest.permission.READ_SMS)) {
                        result.success(emptyList<Map<String, Any?>>())
                        return@setMethodCallHandler
                    }
                    val limit = call.argument<Int>("limit") ?: 500
                    result.success(readRecentSms(limit))
                }

                "readRecentCalls" -> {
                    if (!hasPermission(Manifest.permission.READ_CALL_LOG)) {
                        result.success(emptyList<Map<String, Any?>>())
                        return@setMethodCallHandler
                    }
                    val limit = call.argument<Int>("limit") ?: 500
                    result.success(readRecentCalls(limit))
                }

                "checkHealthConnect" -> result.success(checkHealthConnect())

                "openHealthConnect" -> {
                    openHealthConnect()
                    result.success(true)
                }

                "readHealthSummary" -> {
                    val days = call.argument<Int>("days") ?: 30
                    readHealthSummary(days, result)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun configureAppsChannel(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listSupportedApps" -> result.success(listSupportedApps())
                "handoffPromptToAiApp" -> {
                    val prompt = call.argument<String>("prompt")?.trim() ?: ""
                    val preferredAppId = call.argument<String>("preferredAppId")
                    if (prompt.isBlank()) {
                        result.error("invalid_prompt", "Prompt is required.", null)
                        return@setMethodCallHandler
                    }
                    result.success(handoffPromptToAiApp(prompt, preferredAppId))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startListening(result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) {
            result.error("microphone_denied", "Microphone permission is required.", null)
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("speech_unavailable", "Speech recognition is unavailable.", null)
            return
        }

        speechRecognizer?.destroy()
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
            setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = Unit
                override fun onBeginningOfSpeech() = Unit
                override fun onRmsChanged(rmsdB: Float) = Unit
                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onEndOfSpeech() = Unit
                override fun onEvent(eventType: Int, params: Bundle?) = Unit

                override fun onPartialResults(partialResults: Bundle?) {
                    val text = firstSpeechText(partialResults)
                    if (text.isNotBlank()) {
                        voiceChannel?.invokeMethod("onPartialTranscript", text)
                    }
                }

                override fun onResults(results: Bundle?) {
                    val text = firstSpeechText(results)
                    voiceChannel?.invokeMethod("onFinalTranscript", text)
                }

                override fun onError(error: Int) {
                    voiceChannel?.invokeMethod(
                        "onVoiceError",
                        speechErrorText(error),
                    )
                }
            })
        }

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Speak a PIE command")
        }
        speechRecognizer?.startListening(intent)
        result.success(true)
    }

    private fun firstSpeechText(bundle: Bundle?): String {
        return bundle
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            ?.trim()
            ?: ""
    }

    private fun speechErrorText(error: Int): String {
        return when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "Audio capture failed."
            SpeechRecognizer.ERROR_CLIENT -> "Speech client failed."
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is required."
            SpeechRecognizer.ERROR_NETWORK -> "Speech network error."
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech network timed out."
            SpeechRecognizer.ERROR_NO_MATCH -> "I did not catch a command."
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognizer is busy."
            SpeechRecognizer.ERROR_SERVER -> "Speech server failed."
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech detected."
            else -> "Speech recognition failed."
        }
    }

    private fun initializeTextToSpeech() {
        if (textToSpeech != null) return
        textToSpeech = TextToSpeech(this) { status ->
            textToSpeechReady = status == TextToSpeech.SUCCESS
            if (textToSpeechReady) {
                textToSpeech?.language = Locale.getDefault()
            }
        }
    }

    private fun speak(text: String) {
        if (text.isBlank()) return
        if (!textToSpeechReady) initializeTextToSpeech()
        textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "pie_tts")
    }

    private fun searchContacts(query: String): List<Map<String, String>> {
        val trimmedQuery = query.trim()
        if (trimmedQuery.isEmpty()) return emptyList()
        return queryPhoneContacts(trimmedQuery, 12)
    }

    private fun listPhoneContacts(limit: Int): List<Map<String, String>> {
        return queryPhoneContacts("", limit.coerceIn(1, 2_000))
    }

    private fun queryPhoneContacts(query: String, limit: Int): List<Map<String, String>> {
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
        )
        val selection =
            if (query.isBlank()) {
                null
            } else {
                "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY} LIKE ? OR " +
                    "${ContactsContract.CommonDataKinds.Phone.NUMBER} LIKE ?"
            }
        val args = if (query.isBlank()) null else arrayOf("%$query%", "%$query%")
        val contacts = linkedMapOf<String, Map<String, String>>()

        contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection,
            selection,
            args,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY} ASC",
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            )
            val nameIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY,
            )
            val numberIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )

            while (cursor.moveToNext() && contacts.size < limit) {
                val id = cursor.getString(idIndex) ?: continue
                val name = cursor.getString(nameIndex) ?: ""
                val number = cursor.getString(numberIndex) ?: ""
                val normalized = normalizePhone(number)
                if (normalized.isBlank()) continue
                val key = "$id:$normalized"
                contacts[key] = mapOf(
                    "id" to id,
                    "displayName" to name,
                    "phoneNumber" to number,
                    "normalizedPhoneNumber" to normalized,
                    "source" to "contacts",
                )
            }
        }

        return contacts.values.toList()
    }

    private fun searchEmailContacts(query: String): List<Map<String, String>> {
        val trimmedQuery = query.trim()
        if (trimmedQuery.isEmpty()) return emptyList()
        return queryEmailContacts(trimmedQuery, 12)
    }

    private fun listEmailContacts(limit: Int): List<Map<String, String>> {
        return queryEmailContacts("", limit.coerceIn(1, 2_000))
    }

    private fun queryEmailContacts(query: String, limit: Int): List<Map<String, String>> {
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Email.CONTACT_ID,
            ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY,
            ContactsContract.CommonDataKinds.Email.ADDRESS,
        )
        val selection =
            if (query.isBlank()) {
                null
            } else {
                "${ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY} LIKE ? OR " +
                    "${ContactsContract.CommonDataKinds.Email.ADDRESS} LIKE ?"
            }
        val args = if (query.isBlank()) null else arrayOf("%$query%", "%$query%")
        val contacts = linkedMapOf<String, Map<String, String>>()

        contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            projection,
            selection,
            args,
            "${ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY} ASC",
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Email.CONTACT_ID,
            )
            val nameIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY,
            )
            val addressIndex = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Email.ADDRESS,
            )

            while (cursor.moveToNext() && contacts.size < limit) {
                val id = cursor.getString(idIndex) ?: continue
                val name = cursor.getString(nameIndex) ?: ""
                val address = cursor.getString(addressIndex)?.trim()?.lowercase() ?: ""
                if (address.isBlank()) continue
                val key = "$id:$address"
                contacts[key] = mapOf(
                    "id" to id,
                    "displayName" to name,
                    "phoneNumber" to "",
                    "normalizedPhoneNumber" to "",
                    "emailAddress" to address,
                    "source" to "contacts",
                    "recipientKind" to "contact",
                )
            }
        }

        return contacts.values.toList()
    }

    private fun startWhatsAppMessage(
        actionId: String,
        recipientName: String,
        phoneNumber: String,
        message: String,
        unlockPolicy: String,
    ): Map<String, String> {
        if (actionId.isBlank() || phoneNumber.isBlank() || message.isBlank()) {
            return mapOf(
                "status" to "failed",
                "message" to "Action id, phone number, and message are required.",
            )
        }
        val whatsAppPackage = getWhatsAppPackage()
        if (whatsAppPackage == null) {
            return mapOf("status" to "failed", "message" to "WhatsApp is not installed.")
        }
        if (!isPieAccessibilityEnabled()) {
            return mapOf(
                "status" to "failed",
                "message" to "PIE Capture Service is disabled. Open PIE Settings > Capture Service and enable it.",
            )
        }

        val waPhone = phoneNumber.filter { it.isDigit() }
        if (waPhone.length < 8) {
            return mapOf(
                "status" to "failed",
                "message" to "The selected contact does not have a WhatsApp-ready number.",
            )
        }

        return try {
            PieAccessibilityService.queueWhatsAppMessage(
                context = applicationContext,
                actionId = actionId,
                recipientName = recipientName,
                phoneNumber = phoneNumber,
                message = message,
                unlockPolicy = unlockPolicy,
            )

            val encodedMessage = URLEncoder.encode(message, Charsets.UTF_8.name())
            val uri = Uri.parse("https://wa.me/$waPhone?text=$encodedMessage")
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage(whatsAppPackage)
            }
            startActivityWithFallback(
                intent,
                Intent(Intent.ACTION_SENDTO).apply {
                    data = Uri.parse("smsto:$waPhone")
                    setPackage(whatsAppPackage)
                    putExtra("sms_body", message)
                },
            )
            mapOf(
                "status" to "started",
                "message" to "WhatsApp opened. If app lock appears, unlock WhatsApp once; PIE will resume this approved action after verification.",
            )
        } catch (error: Exception) {
            PieAccessibilityService.clearPendingAction(actionId)
            mapOf(
                "status" to "failed",
                "message" to "Failed to open WhatsApp: ${error.message ?: "unknown error"}",
            )
        }
    }

    private fun isEmailAvailable(): Boolean {
        val intent = Intent(Intent.ACTION_SENDTO).apply {
            data = Uri.parse("mailto:")
        }
        return intent.resolveActivity(packageManager) != null
    }

    private fun composeEmail(
        emailAddress: String,
        subject: String,
        body: String,
        attachmentPaths: List<String>,
    ): Map<String, String> {
        if (emailAddress.isBlank() || body.isBlank()) {
            return mapOf(
                "status" to "failed",
                "message" to "Email recipient and body are required.",
            )
        }

        return try {
            val attachmentUris = attachmentPaths
                .mapNotNull { path -> fileUriForEmailAttachment(path) }
                .toCollection(arrayListOf())
            if (attachmentPaths.isNotEmpty() && attachmentUris.isEmpty()) {
                return mapOf(
                    "status" to "failed",
                    "message" to "Selected email attachment files are not accessible.",
                )
            }
            val intent =
                if (attachmentUris.isEmpty()) {
                    Intent(Intent.ACTION_SENDTO).apply {
                        data = Uri.parse("mailto:")
                        putExtra(Intent.EXTRA_EMAIL, arrayOf(emailAddress))
                        putExtra(Intent.EXTRA_SUBJECT, subject)
                        putExtra(Intent.EXTRA_TEXT, body)
                    }
                } else {
                    Intent(
                        if (attachmentUris.size == 1) {
                            Intent.ACTION_SEND
                        } else {
                            Intent.ACTION_SEND_MULTIPLE
                        },
                    ).apply {
                        type = "*/*"
                        putExtra(Intent.EXTRA_EMAIL, arrayOf(emailAddress))
                        putExtra(Intent.EXTRA_SUBJECT, subject)
                        putExtra(Intent.EXTRA_TEXT, body)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        if (attachmentUris.size == 1) {
                            putExtra(Intent.EXTRA_STREAM, attachmentUris.first())
                            clipData = ClipData.newUri(
                                contentResolver,
                                "PIE email attachment",
                                attachmentUris.first(),
                            )
                        } else {
                            putParcelableArrayListExtra(Intent.EXTRA_STREAM, attachmentUris)
                            val clip = ClipData.newUri(
                                contentResolver,
                                "PIE email attachment",
                                attachmentUris.first(),
                            )
                            attachmentUris.drop(1).forEach { uri ->
                                clip.addItem(ClipData.Item(uri))
                            }
                            clipData = clip
                        }
                    }
                }
            if (intent.resolveActivity(packageManager) == null) {
                return mapOf("status" to "failed", "message" to "No email app is available.")
            }
            startActivity(intent)
            mapOf("status" to "started", "message" to "Email compose opened for review.")
        } catch (error: Exception) {
            mapOf(
                "status" to "failed",
                "message" to "Failed to open email compose: ${error.message ?: "unknown error"}",
            )
        }
    }

    private fun fileUriForEmailAttachment(path: String): Uri? {
        if (path.isBlank()) return null
        val file = File(path)
        if (!file.exists() || !file.isFile) return null
        return FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
    }

    private fun readRecentSms(limit: Int): List<Map<String, Any?>> {
        val safeLimit = limit.coerceIn(1, 2_000)
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE,
            Telephony.Sms.THREAD_ID,
        )
        val messages = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            projection,
            null,
            null,
            "${Telephony.Sms.DATE} DESC",
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addressIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val typeIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.TYPE)
            val threadIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)

            while (cursor.moveToNext() && messages.size < safeLimit) {
                val body = cursor.getString(bodyIndex)?.trim().orEmpty()
                if (body.isBlank()) continue
                messages.add(
                    mapOf(
                        "id" to cursor.getString(idIndex),
                        "address" to (cursor.getString(addressIndex) ?: ""),
                        "body" to body,
                        "date" to cursor.getLong(dateIndex),
                        "type" to cursor.getInt(typeIndex),
                        "threadId" to cursor.getString(threadIndex),
                    ),
                )
            }
        }
        return messages
    }

    private fun isDefaultSmsApp(): Boolean {
        return Telephony.Sms.getDefaultSmsPackage(this) == packageName
    }

    private fun requestDefaultSmsRole() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = getSystemService(RoleManager::class.java)
            if (roleManager != null && roleManager.isRoleAvailable(RoleManager.ROLE_SMS)) {
                startActivity(roleManager.createRequestRoleIntent(RoleManager.ROLE_SMS))
                return
            }
        }

        val intent = Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).apply {
            putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, packageName)
        }
        startActivity(intent)
    }

    private fun deleteSmsById(id: String): Map<String, String> {
        if (!isDefaultSmsApp()) {
            return mapOf(
                "status" to "blocked",
                "message" to "PIE must be the default SMS app before Android allows SMS deletion.",
            )
        }
        val numericId = id.toLongOrNull()
            ?: return mapOf("status" to "failed", "message" to "Invalid SMS id.")
        val uri = ContentUris.withAppendedId(Telephony.Sms.CONTENT_URI, numericId)
        val deleted = contentResolver.delete(uri, null, null)
        return if (deleted > 0) {
            mapOf("status" to "deleted", "message" to "SMS deleted.")
        } else {
            mapOf("status" to "failed", "message" to "SMS was not found or could not be deleted.")
        }
    }

    private fun readRecentCalls(limit: Int): List<Map<String, Any?>> {
        val safeLimit = limit.coerceIn(1, 2_000)
        val projection = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.NUMBER,
            CallLog.Calls.CACHED_NAME,
            CallLog.Calls.DATE,
            CallLog.Calls.DURATION,
            CallLog.Calls.TYPE,
        )
        val calls = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            projection,
            null,
            null,
            "${CallLog.Calls.DATE} DESC",
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(CallLog.Calls._ID)
            val numberIndex = cursor.getColumnIndexOrThrow(CallLog.Calls.NUMBER)
            val nameIndex = cursor.getColumnIndexOrThrow(CallLog.Calls.CACHED_NAME)
            val dateIndex = cursor.getColumnIndexOrThrow(CallLog.Calls.DATE)
            val durationIndex = cursor.getColumnIndexOrThrow(CallLog.Calls.DURATION)
            val typeIndex = cursor.getColumnIndexOrThrow(CallLog.Calls.TYPE)

            while (cursor.moveToNext() && calls.size < safeLimit) {
                val type = cursor.getInt(typeIndex)
                calls.add(
                    mapOf(
                        "id" to cursor.getString(idIndex),
                        "number" to (cursor.getString(numberIndex) ?: ""),
                        "name" to (cursor.getString(nameIndex) ?: ""),
                        "date" to cursor.getLong(dateIndex),
                        "durationSeconds" to cursor.getLong(durationIndex),
                        "type" to type,
                        "typeLabel" to callTypeLabel(type),
                    ),
                )
            }
        }
        return calls
    }

    private fun callTypeLabel(type: Int): String {
        return when (type) {
            CallLog.Calls.INCOMING_TYPE -> "Incoming"
            CallLog.Calls.OUTGOING_TYPE -> "Outgoing"
            CallLog.Calls.MISSED_TYPE -> "Missed"
            CallLog.Calls.REJECTED_TYPE -> "Rejected"
            CallLog.Calls.BLOCKED_TYPE -> "Blocked"
            CallLog.Calls.VOICEMAIL_TYPE -> "Voicemail"
            else -> "Unknown"
        }
    }

    private fun checkHealthConnect(): Map<String, Any> {
        val status = HealthConnectClient.getSdkStatus(this, healthConnectPackage)
        return if (status == HealthConnectClient.SDK_AVAILABLE) {
            mapOf(
                "available" to true,
                "message" to "Health Connect is available for user-approved health data.",
            )
        } else {
            mapOf(
                "available" to false,
                "message" to "Install Health Connect, then connect a supported health provider.",
            )
        }
    }

    private fun openHealthConnect() {
        val settingsIntent = Intent("android.health.connect.action.HEALTH_CONNECT_SETTINGS")
        if (settingsIntent.resolveActivity(packageManager) != null) {
            startActivity(settingsIntent)
            return
        }

        val marketIntent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("market://details?id=com.google.android.apps.healthdata"),
        )
        if (marketIntent.resolveActivity(packageManager) != null) {
            startActivity(marketIntent)
            return
        }

        startActivity(
            Intent(
                Intent.ACTION_VIEW,
                Uri.parse("https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata"),
            ),
        )
    }

    private fun readHealthSummary(days: Int, result: MethodChannel.Result) {
        nativeScope.launch {
            try {
                val rows = withContext(Dispatchers.IO) {
                    readHealthSummaryInternal(days.coerceIn(1, 90))
                }
                result.success(rows)
            } catch (error: SecurityException) {
                result.error(
                    "health_permission_denied",
                    "Grant Steps and Sleep permissions in Health Connect, then import again.",
                    null,
                )
            } catch (error: Exception) {
                result.error(
                    "health_read_failed",
                    error.message ?: "Health Connect read failed.",
                    null,
                )
            }
        }
    }

    private suspend fun readHealthSummaryInternal(days: Int): List<Map<String, Any?>> {
        if (HealthConnectClient.getSdkStatus(this, healthConnectPackage) !=
            HealthConnectClient.SDK_AVAILABLE
        ) {
            throw IllegalStateException("Health Connect is not available.")
        }

        val client = HealthConnectClient.getOrCreate(this)
        val granted = client.permissionController.getGrantedPermissions()
        if (!granted.containsAll(healthPermissions)) {
            throw SecurityException("Health Connect Steps/Sleep permissions are missing.")
        }

        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val rows = mutableListOf<Map<String, Any?>>()

        for (offset in (days - 1) downTo 0) {
            val date = today.minusDays(offset.toLong())
            val start = date.atStartOfDay(zone).toInstant()
            val end = date.plusDays(1).atStartOfDay(zone).toInstant()
            val steps = readStepsForRange(client, start, end)
            val sleep = readSleepForRange(client, start, end)

            rows.add(
                mapOf(
                    "date" to date.toString(),
                    "startAt" to start.toEpochMilli(),
                    "endAt" to end.toEpochMilli(),
                    "steps" to steps,
                    "sleepMinutes" to sleep.totalMinutes,
                    "sleepStart" to (sleep.firstStart?.toString() ?: ""),
                    "sleepEnd" to (sleep.lastEnd?.toString() ?: ""),
                ),
            )
        }

        return rows
    }

    private suspend fun readStepsForRange(
        client: HealthConnectClient,
        start: Instant,
        end: Instant,
    ): Long {
        val aggregate = client.aggregate(
            AggregateRequest(
                metrics = setOf(StepsRecord.COUNT_TOTAL),
                timeRangeFilter = TimeRangeFilter.between(start, end),
            ),
        )
        return aggregate[StepsRecord.COUNT_TOTAL] ?: 0L
    }

    private suspend fun readSleepForRange(
        client: HealthConnectClient,
        start: Instant,
        end: Instant,
    ): SleepSummary {
        val response = client.readRecords(
            ReadRecordsRequest(
                recordType = SleepSessionRecord::class,
                timeRangeFilter = TimeRangeFilter.between(start, end),
            ),
        )
        var totalMinutes = 0L
        var firstStart: Instant? = null
        var lastEnd: Instant? = null

        for (record in response.records) {
            val overlapStart = if (record.startTime.isAfter(start)) record.startTime else start
            val overlapEnd = if (record.endTime.isBefore(end)) record.endTime else end
            if (overlapEnd.isAfter(overlapStart)) {
                totalMinutes += Duration.between(overlapStart, overlapEnd).toMinutes()
            }
            if (firstStart == null || record.startTime.isBefore(firstStart)) {
                firstStart = record.startTime
            }
            if (lastEnd == null || record.endTime.isAfter(lastEnd)) {
                lastEnd = record.endTime
            }
        }

        return SleepSummary(totalMinutes, firstStart, lastEnd)
    }

    data class SleepSummary(
        val totalMinutes: Long,
        val firstStart: Instant?,
        val lastEnd: Instant?,
    )

    private fun listSupportedApps(): List<Map<String, Any>> {
        val knownApps = listOf(
            KnownApp(
                id = "whatsapp",
                name = "WhatsApp",
                packageName = "com.whatsapp",
                capability = "Messages can be opened and verified through approved Capture Service actions.",
            ),
            KnownApp(
                id = "whatsapp_business",
                name = "WhatsApp Business",
                packageName = "com.whatsapp.w4b",
                capability = "Business chats can use the same approved Capture Service path.",
            ),
            KnownApp(
                id = "gmail",
                name = "Gmail",
                packageName = "com.google.android.gm",
                capability = "Email compose and notification context are available after user permission.",
            ),
            KnownApp(
                id = "samsung_email",
                name = "Samsung Email",
                packageName = "com.samsung.android.email.provider",
                capability = "Email compose can use Android mail intents when configured.",
            ),
            KnownApp(
                id = "samsung_health",
                name = "Samsung Health",
                packageName = "com.sec.android.app.shealth",
                capability = "Health data needs user-approved Health Connect or an official provider API.",
            ),
            KnownApp(
                id = "health_connect",
                name = "Health Connect",
                packageName = "com.google.android.apps.healthdata",
                capability = "Official Android health records path for supported apps and granted data types.",
            ),
            KnownApp(
                id = "google_fit",
                name = "Google Fit",
                packageName = "com.google.android.apps.fitness",
                capability = "Fitness data needs Health Connect or Google Fit API authorization.",
            ),
            KnownApp(
                id = "digital_wellbeing",
                name = "Digital Wellbeing",
                packageName = "com.google.android.apps.wellbeing",
                capability = "Usage and wellbeing controls require Android-supported permission surfaces.",
            ),
            KnownApp(
                id = "gemini",
                name = "Gemini",
                packageName = "com.google.android.apps.bard",
                capability = "PIE can open Gemini with a prompt; results stay inside Gemini until you share or save them.",
            ),
            KnownApp(
                id = "chatgpt",
                name = "ChatGPT",
                packageName = "com.openai.chatgpt",
                capability = "PIE can open ChatGPT with a prompt; results stay inside ChatGPT until you share or save them.",
            ),
        )

        return knownApps.map { app ->
            val installed = isPackageInstalled(app.packageName) ||
                (app.id == "health_connect" && Build.VERSION.SDK_INT >= 34)
            mapOf(
                "id" to app.id,
                "name" to app.name,
                "packageName" to app.packageName,
                "installed" to installed,
                "capability" to app.capability,
                "status" to if (installed) "Installed" else "Not installed",
            )
        }
    }

    private fun handoffPromptToAiApp(prompt: String, preferredAppId: String?): Map<String, Any> {
        val aiApps = listOf(
            KnownApp(
                id = "gemini",
                name = "Gemini",
                packageName = "com.google.android.apps.bard",
                capability = "",
            ),
            KnownApp(
                id = "chatgpt",
                name = "ChatGPT",
                packageName = "com.openai.chatgpt",
                capability = "",
            ),
        )
        val orderedApps = if (preferredAppId.isNullOrBlank()) {
            aiApps
        } else {
            aiApps.sortedBy { if (it.id == preferredAppId) 0 else 1 }
        }
        val app = orderedApps.firstOrNull { isPackageInstalled(it.packageName) }
            ?: return mapOf(
                "opened" to false,
                "providerName" to "",
                "packageName" to "",
                "copiedToClipboard" to false,
                "message" to "No supported AI app is installed. Install Gemini or ChatGPT, or configure a backend image provider.",
            )

        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            setPackage(app.packageName)
            putExtra(Intent.EXTRA_TEXT, prompt)
            putExtra(Intent.EXTRA_SUBJECT, "PIE image prompt")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        return try {
            if (sendIntent.resolveActivity(packageManager) != null) {
                startActivity(sendIntent)
                mapOf(
                    "opened" to true,
                    "providerName" to app.name,
                    "packageName" to app.packageName,
                    "copiedToClipboard" to false,
                    "message" to "Opened ${app.name} with your prompt.",
                )
            } else {
                openAiAppWithClipboardFallback(app, prompt)
            }
        } catch (_: Exception) {
            openAiAppWithClipboardFallback(app, prompt)
        }
    }

    private fun openAiAppWithClipboardFallback(app: KnownApp, prompt: String): Map<String, Any> {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("PIE prompt", prompt))
        val launchIntent = packageManager.getLaunchIntentForPackage(app.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (launchIntent != null) {
            try {
                startActivity(launchIntent)
                mapOf(
                    "opened" to true,
                    "providerName" to app.name,
                    "packageName" to app.packageName,
                    "copiedToClipboard" to true,
                    "message" to "Opened ${app.name} and copied your prompt to the clipboard.",
                )
            } catch (_: Exception) {
                mapOf(
                    "opened" to false,
                    "providerName" to app.name,
                    "packageName" to app.packageName,
                    "copiedToClipboard" to true,
                    "message" to "${app.name} could not be opened. Your prompt was copied to the clipboard.",
                )
            }
        } else {
            mapOf(
                "opened" to false,
                "providerName" to app.name,
                "packageName" to app.packageName,
                "copiedToClipboard" to true,
                "message" to "${app.name} is installed, but Android did not expose a launch target. Your prompt was copied to the clipboard.",
            )
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            true
        } else {
            checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestRuntimePermission(permission: String, requestCode: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !hasPermission(permission)) {
            requestPermissions(arrayOf(permission), requestCode)
        }
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun getWhatsAppPackage(): String? {
        return when {
            isPackageInstalled("com.whatsapp") -> "com.whatsapp"
            isPackageInstalled("com.whatsapp.w4b") -> "com.whatsapp.w4b"
            else -> null
        }
    }

    private fun startActivityWithFallback(primary: Intent, fallback: Intent) {
        try {
            startActivity(primary)
        } catch (_: Exception) {
            startActivity(fallback)
        }
    }

    private fun isPieAccessibilityEnabled(): Boolean {
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        val serviceClass = "${packageName}/${PieAccessibilityService::class.java.name}"
        return enabledServices.contains(serviceClass) ||
            enabledServices.contains(PieAccessibilityService::class.java.name)
    }

    private fun normalizePhone(value: String): String {
        val trimmed = value.trim()
        val digits = trimmed.filter { it.isDigit() }
        return if (trimmed.startsWith("+") && digits.isNotEmpty()) {
            "+$digits"
        } else {
            digits
        }
    }

    data class KnownApp(
        val id: String,
        val name: String,
        val packageName: String,
        val capability: String,
    )

    private fun registerAppReceivers() {
        if (receiversRegistered) return

        val appContext = applicationContext
        val notificationFilter = IntentFilter(
            PieNotificationListenerService.ACTION_NOTIFICATION_RECEIVED,
        )
        val connectorFilter = IntentFilter(
            PieAccessibilityService.ACTION_CONNECTOR_EVENT,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(
                notificationReceiver,
                notificationFilter,
                Context.RECEIVER_NOT_EXPORTED,
            )
            appContext.registerReceiver(
                connectorReceiver,
                connectorFilter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            appContext.registerReceiver(notificationReceiver, notificationFilter)
            appContext.registerReceiver(connectorReceiver, connectorFilter)
        }
        receiversRegistered = true
    }

    private fun unregisterAppReceivers() {
        if (!receiversRegistered) return
        try {
            applicationContext.unregisterReceiver(notificationReceiver)
        } catch (_: IllegalArgumentException) {
        }
        try {
            applicationContext.unregisterReceiver(connectorReceiver)
        } catch (_: IllegalArgumentException) {
        }
        receiversRegistered = false
    }

    override fun onDestroy() {
        speechRecognizer?.destroy()
        speechRecognizer = null
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        unregisterAppReceivers()
        nativeScope.cancel()
        super.onDestroy()
    }
}
