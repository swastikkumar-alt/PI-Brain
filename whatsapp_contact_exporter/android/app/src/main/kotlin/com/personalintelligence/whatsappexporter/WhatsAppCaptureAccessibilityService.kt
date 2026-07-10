package com.personalintelligence.whatsappexporter

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class WhatsAppCaptureAccessibilityService : AccessibilityService() {
    companion object {
        const val PREFS_NAME = "wa_group_extractor_capture"
        const val KEY_LATEST_CAPTURE_JSON = "latest_capture_json"
        private const val SOURCE = "whatsapp_accessibility_visible_review"
    }

    private val phoneRegex = Regex("""\+?\d[\d\s().-]{5,}\d""")
    private val adminRegex = Regex("""\b(admin|group admin)\b""", RegexOption.IGNORE_CASE)
    private var lastSavedSignature: String = ""

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val packageName = event?.packageName?.toString().orEmpty()
        if (packageName != "com.whatsapp" && packageName != "com.whatsapp.w4b") {
            return
        }
        val root = rootInActiveWindow ?: return
        val texts = mutableListOf<String>()
        collectTexts(root, texts)
        val payload = buildCapturePayload(texts, packageName) ?: return
        val signature = payload.optJSONArray("members")?.toString().orEmpty()
        if (signature.isBlank() || signature == lastSavedSignature) {
            return
        }
        lastSavedSignature = signature
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putString(KEY_LATEST_CAPTURE_JSON, payload.toString())
            .apply()
    }

    override fun onInterrupt() = Unit

    private fun collectTexts(node: AccessibilityNodeInfo, output: MutableList<String>) {
        node.text?.toString()?.cleanUiText()?.takeIf { it.isNotBlank() }?.let(output::add)
        node.contentDescription?.toString()?.cleanUiText()?.takeIf { it.isNotBlank() }?.let(output::add)
        for (index in 0 until node.childCount) {
            node.getChild(index)?.let { child ->
                collectTexts(child, output)
            }
        }
    }

    private fun buildCapturePayload(rawTexts: List<String>, sourcePackage: String): JSONObject? {
        val texts = rawTexts
            .map { it.cleanUiText() }
            .filter { it.length in 2..120 }
            .distinct()

        val anchorIndex = texts.indexOfFirst {
            it.contains("participants", ignoreCase = true) ||
                it.contains("members", ignoreCase = true) ||
                it.contains("group info", ignoreCase = true)
        }
        val hasGroupSignals = anchorIndex >= 0 ||
            texts.any { adminRegex.containsMatchIn(it) } ||
            texts.count { phoneRegex.containsMatchIn(it) } >= 2
        if (!hasGroupSignals) {
            return null
        }

        val groupName = inferGroupName(texts, anchorIndex)
        val members = JSONArray()
        val candidateTexts = if (anchorIndex >= 0) texts.drop(anchorIndex + 1) else texts
        val seen = linkedSetOf<String>()

        for (text in candidateTexts) {
            if (members.length() >= 250) {
                break
            }
            if (isUiNoise(text)) {
                continue
            }
            val phone = phoneRegex.find(text)?.value.orEmpty()
            val isAdmin = adminRegex.containsMatchIn(text)
            val displayName = text
                .replace(phone, " ")
                .replace(adminRegex, " ")
                .replace(Regex("""[,;|•]+"""), " ")
                .replace(Regex("""\s{2,}"""), " ")
                .trim()

            val includeLowConfidenceName =
                anchorIndex >= 0 && phone.isBlank() && looksLikeVisibleMemberName(displayName)
            if (phone.isBlank() && !isAdmin && !includeLowConfidenceName) {
                continue
            }

            val key = normalizePhone(phone).ifBlank { displayName.lowercase(Locale.US) }
            if (key.isBlank() || !seen.add(key)) {
                continue
            }
            val confidence = when {
                phone.isNotBlank() -> "high"
                isAdmin -> "medium"
                else -> "low"
            }
            members.put(
                JSONObject()
                    .put("id", "")
                    .put("group_id", "")
                    .put("display_name", displayName.ifBlank { phone })
                    .put("phone", phone)
                    .put("normalized_phone", normalizePhone(phone))
                    .put("role", if (isAdmin) "admin" else "unknown")
                    .put("confidence", confidence)
                    .put("source", SOURCE),
            )
        }

        if (members.length() == 0) {
            return null
        }
        return JSONObject()
            .put("group_name", groupName)
            .put("source_account_label", sourcePackage)
            .put("captured_at", utcNow())
            .put("members", members)
    }

    private fun inferGroupName(texts: List<String>, anchorIndex: Int): String {
        val candidates = if (anchorIndex > 0) texts.take(anchorIndex) else texts.take(8)
        return candidates.firstOrNull {
            !isUiNoise(it) &&
                !phoneRegex.containsMatchIn(it) &&
                !it.contains("admin", ignoreCase = true) &&
                !it.contains("participants", ignoreCase = true)
        } ?: "WhatsApp group"
    }

    private fun looksLikeVisibleMemberName(value: String): Boolean {
        if (value.length !in 2..60) {
            return false
        }
        if (value.any { it.isDigit() }) {
            return false
        }
        if (isUiNoise(value)) {
            return false
        }
        val compact = value.compactUiKey()
        if (compact.length <= 2) {
            return false
        }
        if (compact in compactNoiseKeys) {
            return false
        }
        if (value.split(Regex("""\s+""")).count { it.length == 1 } >= 4) {
            return false
        }
        return value.any { it.isLetter() }
    }

    private fun isUiNoise(value: String): Boolean {
        val lower = value.lowercase(Locale.US).trim()
        val compact = value.compactUiKey()
        val exactNoise = setOf(
            "add",
            "about",
            "back",
            "search",
            "more options",
            "message",
            "messages",
            "audio",
            "video",
            "call",
            "calls",
            "voice call",
            "video call",
            "voicechat",
            "voice chat",
            "mute notifications",
            "notifications",
            "encryption",
            "media visibility",
            "media links and docs",
            "media, links, and docs",
            "starred messages",
            "chat lock",
            "wallpaper",
            "group permissions",
            "group settings",
            "group info",
            "members",
            "participants",
            "add members",
            "invite via link",
            "view all",
            "exit group",
            "report group",
            "block",
            "delete",
            "edit",
            "share",
            "copy",
            "qr code",
        )
        if (lower in exactNoise || compact in compactNoiseKeys) {
            return true
        }
        return lower.startsWith("last seen") ||
            lower.startsWith("online") ||
            lower.startsWith("created by") ||
            lower.startsWith("tap to") ||
            lower.contains("encryption") ||
            lower.contains("disappearing messages") ||
            lower.contains("tap for more info") ||
            lower.endsWith("message unread") ||
            lower.contains("tap for more info")
    }

    private val compactNoiseKeys = setOf(
        "add",
        "about",
        "admin",
        "admins",
        "audio",
        "back",
        "block",
        "call",
        "calls",
        "chatlock",
        "copy",
        "delete",
        "edit",
        "encryption",
        "exitgroup",
        "groupinfo",
        "grouppermissions",
        "groupsettings",
        "invitevialink",
        "media",
        "medialinksanddocs",
        "members",
        "message",
        "messages",
        "moreoptions",
        "mutenotifications",
        "notifications",
        "participants",
        "qrcode",
        "reportgroup",
        "search",
        "share",
        "starredmessages",
        "video",
        "videocall",
        "viewall",
        "voicecall",
        "voicechat",
        "wallpaper",
    )

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

    private fun utcNow(): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formatter.timeZone = TimeZone.getTimeZone("UTC")
        return formatter.format(Date())
    }

    private fun String.cleanUiText(): String {
        return replace('\n', ' ')
            .replace(Regex("""\s{2,}"""), " ")
            .trim()
    }

    private fun String.compactUiKey(): String {
        return lowercase(Locale.US).replace(Regex("""[^a-z0-9]+"""), "")
    }
}
