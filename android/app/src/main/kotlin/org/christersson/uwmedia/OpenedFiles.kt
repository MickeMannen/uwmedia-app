package org.christersson.uwmedia

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Dive logs opened with UWMedia or shared to it (spec §12.3 step 1): each
 * file copied out of its content URI into a folder of its own in the
 * cache, the copies waiting until the app takes them ("take"), and their
 * folder removed once the app has kept them ("done").
 */
class OpenedFiles(private val context: Context) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableListOf<String>()
    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "uwmedia/opened_files").also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "take" -> {
                result.success(pending.toList())
                pending.clear()
            }
            "done" -> {
                val paths = call.arguments as? List<*> ?: emptyList<Any>()
                worker.execute {
                    for (path in paths.filterIsInstance<String>()) {
                        release(path)
                    }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The files of [intent] (a view or a share), copied and announced. */
    fun receive(intent: Intent?) {
        val uris = intent?.let(::urisOf) ?: return
        if (uris.isEmpty()) {
            return
        }
        worker.execute {
            val folder = File(File(context.cacheDir, "opened"), UUID.randomUUID().toString())
            folder.mkdirs()
            val copied = uris.mapNotNull { copy(it, folder) }
            main.post {
                pending.addAll(copied)
                channel?.invokeMethod("available", null)
            }
        }
    }

    /**
     * The files picked in the system's picker, copied a piece at a time
     * into a folder of their own in the cache, and given to [done] on the
     * main thread as each copy's path and the file's own name; a file that
     * could not be read is left out. `file_selector` read each picked file
     * whole into memory, and a large video closed the app.
     */
    fun copyPicked(uris: List<Uri>, done: (List<Map<String, String>>) -> Unit) {
        worker.execute {
            val folder = File(File(context.cacheDir, "picked"), UUID.randomUUID().toString())
            // A folder for each file: two picked files may share a name.
            val copied = uris.mapIndexedNotNull { i, uri ->
                val own = File(folder, "$i").apply { mkdirs() }
                copy(uri, own)?.let { mapOf("path" to it, "name" to File(it).name) }
            }
            main.post { done(copied) }
        }
    }

    @Suppress("DEPRECATION")
    private fun urisOf(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_VIEW -> listOfNotNull(intent.data)
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
        )
        Intent.ACTION_SEND_MULTIPLE ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            } ?: emptyList()
        else -> emptyList()
    }

    // One file copied into [folder] under its own name; null when it could
    // not be read.
    private fun copy(uri: Uri, folder: File): String? {
        var target: File? = null
        return try {
            target = File(folder, nameOf(uri))
            context.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { input.copyTo(it) }
            } ?: throw IllegalStateException("no stream")
            target.path
        } catch (e: Exception) {
            android.util.Log.w("UWMedia", "Could not copy the opened file $uri: $e")
            // Not a part of it left behind.
            target?.delete()
            null
        }
    }

    private fun nameOf(uri: Uri): String {
        var name: String? = null
        if (uri.scheme == "content") {
            context.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) {
                    name = cursor.getString(0)
                }
            }
        }
        val plain = (name ?: uri.lastPathSegment ?: "").substringAfterLast('/').trim()
        // Never a name that leads out of the copy's folder.
        return if (plain.isEmpty() || plain == "." || plain == "..") "opened" else plain
    }

    // A copy and, once it is empty, its folder; nothing outside the cache.
    private fun release(path: String) {
        val file = File(path)
        val opened = File(context.cacheDir, "opened").canonicalFile
        val folder = file.canonicalFile.parentFile ?: return
        if (folder.parentFile != opened) {
            return
        }
        file.delete()
        if (folder.list()?.isEmpty() == true) {
            folder.delete()
        }
    }
}
