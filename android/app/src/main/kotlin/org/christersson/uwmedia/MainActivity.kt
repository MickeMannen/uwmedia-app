package org.christersson.uwmedia

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val PICK_TREE = 4711
private const val PICK_FILES = 4712

class MainActivity : FlutterActivity() {
    private var opened: OpenedFiles? = null

    @OptIn(UnstableApi::class)
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val library = MediaLibrary(applicationContext, ::pickTree)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uwmedia/media_library")
            .setMethodCallHandler(library::handle)
        val engine = MediaEngine(applicationContext)
        RunService.percent = engine::currentProgress
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uwmedia/media_engine")
            .setMethodCallHandler(engine::handle)
        val screen = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uwmedia/screen")
        // Stop in the run's notification: the Dart side ends the run.
        RunService.onStop = { runOnUiThread { screen.invokeMethod("stopRun", null) } }
        screen
            .setMethodCallHandler { call, result ->
                if (call.method == "runProgress") {
                    // How many of the run's files are done, for the
                    // notification.
                    RunService.files = Pair(
                        call.argument<Int>("done") ?: 0,
                        call.argument<Int>("total") ?: 0,
                    )
                    result.success(null)
                } else if (call.method == "keepAwake") {
                    // The screen stays on during a run, and the run goes on
                    // when the user looks at another app (RunService).
                    if (call.arguments == true) {
                        RunService.files = null
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        askForNotifications()
                        try {
                            RunService.start(applicationContext)
                        } catch (e: RuntimeException) {
                            // Not allowed just now (the app is not on
                            // screen): the run goes on as before.
                        }
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        RunService.stop(applicationContext)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        opened = OpenedFiles(applicationContext).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uwmedia/file_picks")
            .setMethodCallHandler { call, result ->
                if (call.method == "open") {
                    pickFiles(
                        call.argument<List<String>>("mimeTypes").orEmpty(),
                        call.argument<Boolean>("multiple") ?: false,
                        result,
                    )
                } else {
                    result.notImplemented()
                }
            }
    }

    // The system's file picker (file_picks.dart's openFile and openFiles):
    // one at a time, the files copied before they are given back.
    private var filesPicked: MethodChannel.Result? = null

    private fun pickFiles(mimeTypes: List<String>, multiple: Boolean, result: MethodChannel.Result) {
        if (filesPicked != null) {
            result.error("busy", "The file picker is open already", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
        if (mimeTypes.isEmpty()) {
            intent.type = "*/*"
        } else {
            intent.type = if (mimeTypes.size == 1) mimeTypes[0] else "*/*"
            intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
        }
        filesPicked = result
        try {
            startActivityForResult(intent, PICK_FILES)
        } catch (e: ActivityNotFoundException) {
            filesPicked = null
            result.error("no_picker", "The phone has no file picker", null)
        }
    }

    private fun filesPicked(resultCode: Int, data: Intent?) {
        val result = filesPicked ?: return
        filesPicked = null
        val uris = mutableListOf<Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            val clip = data.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) {
                    uris.add(clip.getItemAt(i).uri)
                }
            } else {
                data.data?.let(uris::add)
            }
        }
        if (uris.isEmpty()) {
            result.success(emptyList<Map<String, String>>())
            return
        }
        val files = opened
        if (files == null) {
            result.error("read", "The file could not be read", null)
            return
        }
        files.copyPicked(uris) { copied ->
            if (copied.isEmpty()) {
                result.error("read", "The file could not be read", null)
            } else {
                result.success(copied)
            }
        }
    }

    // The system's folder picker ("Save to"): one at a time, its answer
    // given to who asked.
    private var treePicked: ((Uri?) -> Unit)? = null

    private fun pickTree(answer: (Uri?) -> Unit) {
        if (treePicked != null) {
            answer(null)
            return
        }
        treePicked = answer
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_TREE)
        } catch (e: ActivityNotFoundException) {
            // A device without the system's picker.
            treePicked = null
            answer(null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == PICK_FILES) {
            filesPicked(resultCode, data)
            return
        }
        if (requestCode != PICK_TREE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val answer = treePicked
        treePicked = null
        answer?.invoke(if (resultCode == Activity.RESULT_OK) data?.data else null)
    }

    // The run's notification needs the user's yes from Android 13 on;
    // without it the run still goes on, only unseen.
    private var askedForNotifications = false

    private fun askForNotifications() {
        if (askedForNotifications) {
            // Once a start of the app: not again in the middle of a run.
            return
        }
        askedForNotifications = true
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onDestroy() {
        // The run ends with the activity (the Dart side goes with it).
        RunService.onStop = null
        RunService.files = null
        RunService.stop(applicationContext)
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A restored activity, or one started again from the recent apps,
        // carries the intent its files were already taken from.
        val again = intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !again) {
            opened?.receive(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        opened?.receive(intent)
    }
}
