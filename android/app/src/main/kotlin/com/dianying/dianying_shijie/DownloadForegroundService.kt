package com.dianying.dianying_shijie

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/// v1.9.8 下载前台服务：下载期间通知栏常驻一条进度通知，
/// 防止锁屏/切后台后系统冻结应用、掐断网络导致下载停止（靳老师 2026-09-23）
/// v2.0 通知加点击跳转（点通知打开 App 并进「下载管理」页）；新增「下载完成」通知
class DownloadForegroundService : Service() {
    companion object {
        private const val CH_ID = "download_fg"
        private const val CH_ID_DONE = "download_done"
        private const val NOTIF_ID = 20260923
        private const val NOTIF_ID_DONE = 20260924
        @Volatile var instance: DownloadForegroundService? = null
        @Volatile var currentText: String = "正在下载视频…"

        fun start(context: Context) {
            val i = Intent(context, DownloadForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                context.startForegroundService(i)
            else
                context.startService(i)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }

        private fun pendingFlags(): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else
                @Suppress("DEPRECATION") PendingIntent.FLAG_UPDATE_CURRENT

        /// v2.0 点击通知 → 打开 App 并跳转「下载管理」页（冷/热启动都生效）
        private fun openDownloadIntent(context: Context, req: Int): PendingIntent {
            val i = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("open_download", true)
            }
            return PendingIntent.getActivity(context, req, i, pendingFlags())
        }

        /// v2.0「下载完成」通知：此前下载完只是撤掉进度通知，没有任何完成提示
        fun notifyDone(context: Context, movie: String, ep: String) {
            try {
                val nm = context
                    .getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            CH_ID_DONE, "下载完成",
                            NotificationManager.IMPORTANCE_DEFAULT
                        ).apply { setShowBadge(true) }
                    )
                }
                val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    Notification.Builder(context, CH_ID_DONE)
                else
                    @Suppress("DEPRECATION") Notification.Builder(context)
                val text = if (ep.isEmpty()) "已保存到本地" else "$ep 已保存到本地"
                nm.notify(
                    NOTIF_ID_DONE,
                    b.setContentTitle(if (movie.isEmpty()) "下载完成" else "$movie 下载完成")
                        .setContentText(text)
                        .setSmallIcon(android.R.drawable.stat_sys_download_done)
                        .setContentIntent(openDownloadIntent(context, 1002))
                        .setAutoCancel(true)
                        .build()
                )
            } catch (_: Exception) {}
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val notif = buildNotif(currentText)
        // Android 14（API 34）起 dataSync 类型必须在启动时声明，否则崩溃
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
        return START_STICKY
    }

    fun updateText(text: String) {
        currentText = text
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, buildNotif(text))
        } catch (_: Exception) {}
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CH_ID, "视频下载", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(ch)
        }
    }

    private fun buildNotif(text: String): Notification {
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CH_ID)
        else
            @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setContentTitle("电影世界正在下载")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(openDownloadIntent(this, 1001)) // v2.0 点击进下载管理
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }
}
