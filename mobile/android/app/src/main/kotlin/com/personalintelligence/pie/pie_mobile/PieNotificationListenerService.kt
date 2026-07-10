package com.personalintelligence.pie.pie_mobile

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.content.Intent

class PieNotificationListenerService : NotificationListenerService() {

    companion object {
        const val ACTION_NOTIFICATION_RECEIVED = "com.personalintelligence.pie.NOTIFICATION_RECEIVED"
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val sourcePackageName = sbn.packageName
        
        // Filter for WhatsApp and Gmail
        if (sourcePackageName == "com.whatsapp" || sourcePackageName == "com.google.android.gm") {
            val extras = sbn.notification.extras
            val title = extras.getString(Notification.EXTRA_TITLE) ?: ""
            val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""

            if (title.isNotEmpty() && text.isNotEmpty()) {
                val intent = Intent(ACTION_NOTIFICATION_RECEIVED)
                intent.setPackage(applicationContext.packageName)
                intent.putExtra("packageName", sourcePackageName)
                intent.putExtra("title", title)
                intent.putExtra("text", text)
                sendBroadcast(intent)
            }
        }
    }
}
