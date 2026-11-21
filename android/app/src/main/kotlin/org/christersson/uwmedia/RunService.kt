package org.christersson.uwmedia

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Keeps a run going while the app is not on screen (user story 8, U8.3):
 * a foreground service with a notification for as long as a run lasts.
 * The run itself stays where it is, in the app's own process (the Dart
 * side and the media engine); the service only tells Android that the
 * process is doing work the user asked for, so that it is not frozen
 * when the user looks at another app or the screen goes off.
 */
class RunService : Service() {
    companion object {
        private const val CHANNEL = "runs"
        private const val ID = 1
        private const val ACTION_STOP = "org.christersson.uwmedia.STOP_RUN"

        // FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING, there from Android 15.
        private const val TYPE_MEDIA_PROCESSING = 1 shl 13

        /** The percent of the encode going on, or null; set by the activity. */
        @Volatile
        var percent: (() -> Int?)? = null

        /** The run's files done and in all, or null; set by the activity. */
        @Volatile
        var files: Pair<Int, Int>? = null

        /** Ends the run (Stop in the notification); set by the activity. */
        @Volatile
        var onStop: (() -> Unit)? = null

        private val main = Handler(Looper.getMainLooper())
        private var stopping: Runnable? = null

        fun start(context: Context) {
            stopping?.let(main::removeCallbacks)
            stopping = null
            context.startForegroundService(Intent(context, RunService::class.java))
        }

        // A moment later: a run that ended at once must not stop the
        // service before it has shown its notification, which Android
        // takes for a service that never did.
        fun stop(context: Context) {
            stopping?.let(main::removeCallbacks)
            val stop = Runnable {
                stopping = null
                context.stopService(Intent(context, RunService::class.java))
            }
            stopping = stop
            main.postDelayed(stop, 1500)
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            getSystemService(NotificationManager::class.java).notify(ID, notification())
            handler.postDelayed(this, 1000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // The run ends on the Dart side, and the service with it;
            // with nobody there to end one, the service goes by itself.
            val stop = onStop
            if (stop == null) stopSelf() else stop()
            return START_NOT_STICKY
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Runs", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while UWMedia is working on your photos and videos"
            },
        )
        val type = if (Build.VERSION.SDK_INT >= 35) {
            TYPE_MEDIA_PROCESSING
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        }
        startForeground(ID, notification(), type)
        handler.removeCallbacks(tick)
        handler.postDelayed(tick, 1000)
        // A run does not come back by itself after the process was ended.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    // Android 15 ends a media-processing service after six hours a day.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, RunService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val done = percent?.invoke()
        val run = files?.takeIf { it.second > 1 }
        // "File 3 of 7 · 40 %": the file being worked on, and how far.
        val text = listOfNotNull(
            run?.let { "File ${minOf(it.first + 1, it.second)} of ${it.second}" },
            done?.let { if (run == null) "This file: $it %" else "$it %" },
        ).joinToString(" · ").ifEmpty { "Tap to see how far it is" }
        val builder = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("UWMedia is working")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null as android.graphics.drawable.Icon?, "Stop", stop).build())
        if (run != null) {
            // The whole run: the files done and the share of this one.
            builder.setProgress(
                run.second * 100,
                minOf(run.first, run.second) * 100 + (done ?: 0),
                false,
            )
        } else if (done != null) {
            builder.setProgress(100, done, false)
        }
        return builder.build()
    }
}
