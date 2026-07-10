package com.personalintelligence.pie.pie_mobile

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.provider.ContactsContract
import android.provider.Telephony
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URLEncoder
import java.util.Locale

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

                "readRecentSms" -> {
                    if (!hasPermission(Manifest.permission.READ_SMS)) {
                        result.success(emptyList<Map<String, Any?>>())
                        return@setMethodCallHandler
                    }
                    val limit = call.argument<Int>("limit") ?: 500
                    result.success(readRecentSms(limit))
                }

                "checkHealthConnect" -> result.success(checkHealthConnect())

                "openHealthConnect" -> {
                    openHealthConnect()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun configureAppsChannel(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listSupportedApps" -> result.success(listSupportedApps())
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

    private fun checkHealthConnect(): Map<String, Any> {
        val installed = isPackageInstalled("com.google.android.apps.healthdata")
        return if (installed || Build.VERSION.SDK_INT >= 34) {
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
        super.onDestroy()
    }
}
