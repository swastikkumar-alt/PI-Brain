package com.personalintelligence.pie.pie_mobile

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class PieAccessibilityService : AccessibilityService() {
    data class PendingWhatsAppAction(
        val actionId: String,
        val recipientName: String,
        val phoneNumber: String,
        val message: String,
        val unlockPolicy: String,
        val expiresAt: Long,
        var lastDiagnostic: String = "Opening WhatsApp. If app lock appears, unlock WhatsApp and PIE will continue.",
        var textInjected: Boolean = false,
        var sendAttempted: Boolean = false,
    )

    companion object {
        const val ACTION_CONNECTOR_EVENT = "com.personalintelligence.pie.CONNECTOR_EVENT"
        private const val WHATSAPP_PACKAGE = "com.whatsapp"
        private const val WHATSAPP_BUSINESS_PACKAGE = "com.whatsapp.w4b"
        private const val ACTION_TTL_UNLOCK_EACH_TIME_MS = 180_000L
        private const val ACTION_TTL_SESSION_UNLOCK_MS = 600_000L

        @Volatile
        private var pendingWhatsAppAction: PendingWhatsAppAction? = null

        fun queueWhatsAppMessage(
            context: Context,
            actionId: String,
            recipientName: String,
            phoneNumber: String,
            message: String,
            unlockPolicy: String,
        ) {
            val ttlMs = when (unlockPolicy) {
                "sessionUnlock" -> ACTION_TTL_SESSION_UNLOCK_MS
                else -> ACTION_TTL_UNLOCK_EACH_TIME_MS
            }
            pendingWhatsAppAction = PendingWhatsAppAction(
                actionId = actionId,
                recipientName = recipientName,
                phoneNumber = phoneNumber,
                message = message,
                unlockPolicy = unlockPolicy,
                expiresAt = SystemClock.elapsedRealtime() + ttlMs,
            )
        }

        fun clearPendingAction(actionId: String) {
            if (pendingWhatsAppAction?.actionId == actionId) {
                pendingWhatsAppAction = null
            }
        }

        private fun sendConnectorEvent(
            context: Context,
            actionId: String,
            status: String,
            message: String,
        ) {
            val intent = Intent(ACTION_CONNECTOR_EVENT).apply {
                setPackage(context.packageName)
                putExtra("actionId", actionId)
                putExtra("status", status)
                putExtra("message", message)
            }
            context.sendBroadcast(intent)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pending = pendingWhatsAppAction ?: return
        if (SystemClock.elapsedRealtime() > pending.expiresAt) {
            pendingWhatsAppAction = null
            sendConnectorEvent(
                applicationContext,
                pending.actionId,
                "failed",
                "WhatsApp verification timed out: ${pending.lastDiagnostic}",
            )
            return
        }

        val eventPackage = event?.packageName?.toString() ?: return
        if (eventPackage != WHATSAPP_PACKAGE && eventPackage != WHATSAPP_BUSINESS_PACKAGE) {
            pending.lastDiagnostic =
                "Waiting for WhatsApp to become active. Unlock WhatsApp if an app-lock screen is open."
            return
        }
        val root = rootInActiveWindow ?: return
        tryExecutePendingAction(root, pending)
    }

    override fun onInterrupt() = Unit

    private fun tryExecutePendingAction(
        root: AccessibilityNodeInfo,
        pending: PendingWhatsAppAction,
    ) {
        if (pending.sendAttempted) return

        val recipientVerified = containsText(root, pending.recipientName) ||
            containsPhoneFragment(root, pending.phoneNumber) ||
            deepLinkedComposeLooksReady(root)
        val messageReady = findEditableWithMessage(root, pending.message) != null
        if (!messageReady) {
            if (recipientVerified && !pending.textInjected) {
                val editable = findAnyEditable(root)
                if (editable != null && setEditableText(editable, pending.message)) {
                    pending.textInjected = true
                    pending.lastDiagnostic =
                        "Inserted the approved message into WhatsApp compose box."
                    return
                }
            }
            if (pending.textInjected) {
                pending.lastDiagnostic =
                    "Approved message was inserted. Waiting for WhatsApp to expose it for verification."
                return
            }
            if (tryAdvancePreComposeScreen(root)) {
                pending.lastDiagnostic =
                    "Accepted WhatsApp pre-compose prompt. Waiting for the approved message to appear."
            } else {
                pending.lastDiagnostic =
                    "Waiting for WhatsApp compose box with the approved message."
            }
            return
        }

        if (!recipientVerified) {
            pending.lastDiagnostic =
                "Message is ready, but WhatsApp recipient verification is not strong enough yet."
            return
        }

        val sendButton = findSendButton(root)
        if (sendButton == null) {
            pending.lastDiagnostic =
                "Message and recipient are verified. Waiting for WhatsApp send button."
            return
        }
        pending.sendAttempted = true
        pendingWhatsAppAction = null
        if (clickNodeOrClickableParent(sendButton)) {
            sendConnectorEvent(
                applicationContext,
                pending.actionId,
                "executed",
                "WhatsApp message sent after recipient and message verification.",
            )
        } else {
            sendConnectorEvent(
                applicationContext,
                pending.actionId,
                "failed",
                "WhatsApp send button was found, but Android rejected the tap.",
            )
        }
    }

    private fun findEditableWithMessage(
        node: AccessibilityNodeInfo?,
        message: String,
    ): AccessibilityNodeInfo? {
        if (node == null) return null
        val className = node.className?.toString().orEmpty()
        val text = node.text?.toString().orEmpty()
        val description = node.contentDescription?.toString().orEmpty()
        if (
            className.contains("EditText", ignoreCase = true) &&
            (text.matchesMessage(message) || description.matchesMessage(message))
        ) {
            return node
        }

        for (index in 0 until node.childCount) {
            val match = findEditableWithMessage(node.getChild(index), message)
            if (match != null) return match
        }
        return null
    }

    private fun findSendButton(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        if (node == null) return null

        val viewId = node.viewIdResourceName?.lowercase().orEmpty()
        val contentDescription = node.contentDescription?.toString()?.lowercase().orEmpty()
        val text = node.text?.toString()?.lowercase().orEmpty()
        val isSendCandidate = node.isVisibleToUser && (
            viewId.endsWith(":id/send") ||
                contentDescription == "send" ||
                contentDescription.contains("send") ||
                text == "send"
            )

        if (isSendCandidate) return node

        for (index in 0 until node.childCount) {
            val match = findSendButton(node.getChild(index))
            if (match != null) return match
        }
        return null
    }

    private fun tryAdvancePreComposeScreen(root: AccessibilityNodeInfo): Boolean {
        val button = findButtonByText(
            root,
            setOf(
                "continue",
                "continue to chat",
                "open chat",
                "ok",
                "use whatsapp",
                "message",
            ),
        ) ?: return false
        return clickNodeOrClickableParent(button)
    }

    private fun findButtonByText(
        node: AccessibilityNodeInfo?,
        labels: Set<String>,
    ): AccessibilityNodeInfo? {
        if (node == null) return null

        val className = node.className?.toString().orEmpty()
        val text = node.text?.toString()?.normalizedForMatch().orEmpty()
        val description = node.contentDescription
            ?.toString()
            ?.normalizedForMatch()
            .orEmpty()
        val isButtonLike = node.isClickable ||
            className.contains("Button", ignoreCase = true) ||
            className.contains("TextView", ignoreCase = true)
        if (node.isVisibleToUser && node.isEnabled && isButtonLike) {
            if (labels.any { label -> text == label || description == label }) {
                return node
            }
        }

        for (index in 0 until node.childCount) {
            val match = findButtonByText(node.getChild(index), labels)
            if (match != null) return match
        }
        return null
    }

    private fun deepLinkedComposeLooksReady(root: AccessibilityNodeInfo): Boolean {
        val sendButton = findSendButton(root) ?: return false
        if (!sendButton.isVisibleToUser || !sendButton.isEnabled) return false
        return findAnyEditable(root) != null
    }

    private fun findAnyEditable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        if (node == null) return null
        val className = node.className?.toString().orEmpty()
        if (node.isVisibleToUser && className.contains("EditText", ignoreCase = true)) {
            return node
        }

        for (index in 0 until node.childCount) {
            val match = findAnyEditable(node.getChild(index))
            if (match != null) return match
        }
        return null
    }

    private fun setEditableText(
        node: AccessibilityNodeInfo,
        message: String,
    ): Boolean {
        if (!node.isVisibleToUser || !node.isEnabled) return false
        val arguments = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                message,
            )
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
    }

    private fun clickNodeOrClickableParent(node: AccessibilityNodeInfo?): Boolean {
        var current = node
        var depth = 0
        while (current != null && depth < 6) {
            if (current.isVisibleToUser && current.isEnabled && current.isClickable) {
                return current.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            }
            current = current.parent
            depth += 1
        }
        return false
    }

    private fun containsText(node: AccessibilityNodeInfo?, needle: String): Boolean {
        val normalizedNeedle = needle.trim().lowercase()
        if (node == null || normalizedNeedle.isEmpty()) return false

        val text = node.text?.toString()?.lowercase().orEmpty()
        val description = node.contentDescription?.toString()?.lowercase().orEmpty()
        if (text.contains(normalizedNeedle) || description.contains(normalizedNeedle)) {
            return true
        }

        for (index in 0 until node.childCount) {
            if (containsText(node.getChild(index), normalizedNeedle)) return true
        }
        return false
    }

    private fun containsPhoneFragment(
        node: AccessibilityNodeInfo?,
        phoneNumber: String,
    ): Boolean {
        val digits = phoneNumber.filter { it.isDigit() }
        if (digits.length < 6) return false
        val tail = digits.takeLast(if (digits.length >= 6) 6 else 4)
        return containsDigits(node, tail) || containsDigits(node, digits.takeLast(4))
    }

    private fun containsDigits(node: AccessibilityNodeInfo?, needle: String): Boolean {
        if (node == null) return false

        val textDigits = node.text?.toString()?.filter { it.isDigit() }.orEmpty()
        val descriptionDigits =
            node.contentDescription?.toString()?.filter { it.isDigit() }.orEmpty()
        if (textDigits.contains(needle) || descriptionDigits.contains(needle)) {
            return true
        }

        for (index in 0 until node.childCount) {
            if (containsDigits(node.getChild(index), needle)) return true
        }
        return false
    }

    private fun String.normalizedForMatch(): String {
        return trim()
            .lowercase()
            .replace(Regex("\\s+"), " ")
    }

    private fun String.matchesMessage(expected: String): Boolean {
        val actual = normalizedForMatch()
        val target = expected.normalizedForMatch()
        return target.isNotEmpty() && actual.contains(target)
    }
}
