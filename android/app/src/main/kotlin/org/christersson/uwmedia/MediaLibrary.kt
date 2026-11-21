package org.christersson.uwmedia

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/**
 * The photo library on Android: a corrected copy saved through MediaStore
 * into a folder of its own, which the gallery shows as an album; or copied
 * into a folder the user picked in the system's picker (a document tree,
 * the leave to write into it kept over the app's restarts).
 */
class MediaLibrary(
    private val context: Context,
    // Shows the system's folder picker and answers the tree picked (null:
    // none); the activity's, as only it can show one.
    private val pickTree: ((Uri?) -> Unit) -> Unit,
) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveToAlbum" -> worker.execute {
                try {
                    saveToAlbum(call.argument<String>("path")!!, call.argument<String>("album")!!)
                    main.post { result.success(null) }
                } catch (e: Exception) {
                    main.post { result.error(e.javaClass.simpleName, e.message, null) }
                }
            }
            "pickFolder" -> pickTree { tree ->
                if (tree == null) {
                    result.success(null)
                } else {
                    worker.execute {
                        try {
                            val picked = keepFolder(tree)
                            main.post { result.success(picked) }
                        } catch (e: Exception) {
                            main.post { result.error("folder", e.message, null) }
                        }
                    }
                }
            }
            "saveToFolder" -> worker.execute {
                try {
                    saveToFolder(
                        call.argument<String>("path")!!,
                        Uri.parse(call.argument<String>("bookmark")!!),
                    )
                    main.post { result.success(null) }
                } catch (e: Exception) {
                    main.post { result.error("folder", e.message, null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun mimeOf(name: String) = when (name.substringAfterLast('.', "").lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "heic", "heif" -> "image/heic"
        "png" -> "image/png"
        "mov" -> "video/quicktime"
        else -> "video/mp4"
    }

    /**
     * The leave to write into [tree] kept over restarts; the folder's name
     * and its address (what the Dart side keeps as the bookmark).
     */
    private fun keepFolder(tree: Uri): Map<String, String> {
        val resolver = context.contentResolver
        resolver.takePersistableUriPermission(
            tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        val folder = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree),
        )
        var name: String? = null
        resolver.query(
            folder, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
        )?.use { if (it.moveToFirst()) name = it.getString(0) }
        return mapOf(
            "name" to (name ?: tree.lastPathSegment?.substringAfterLast(':') ?: "Folder"),
            "bookmark" to tree.toString(),
        )
    }

    /**
     * The file at [path] copied into the folder [tree] under its own name
     * (the folder's provider numbers it when it has one of that name).
     */
    private fun saveToFolder(path: String, tree: Uri) {
        val resolver = context.contentResolver
        if (resolver.persistedUriPermissions.none { it.uri == tree && it.isWritePermission }) {
            throw IllegalStateException("The folder can no longer be written to. Choose it again.")
        }
        val folder = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree),
        )
        val name = File(path).name
        val target = try {
            DocumentsContract.createDocument(resolver, folder, mimeOf(name), name)
        } catch (e: FileNotFoundException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        } ?: throw IllegalStateException("The folder is no longer there. Choose it again.")
        try {
            resolver.openOutputStream(target)!!.use { sink ->
                File(path).inputStream().use { it.copyTo(sink) }
            }
        } catch (e: Exception) {
            // No half-written file left in the folder.
            try {
                DocumentsContract.deleteDocument(resolver, target)
            } catch (ignored: Exception) {
            }
            throw e
        }
    }

    private fun saveToAlbum(path: String, album: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("Saving into an album needs Android 10 or later")
        }
        val name = File(path).name
        val extension = name.substringAfterLast('.', "").lowercase()
        val photo = extension in setOf("jpg", "jpeg", "heic", "heif", "png")
        val mime = mimeOf(name)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, (if (photo) "Pictures/" else "Movies/") + album)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val collection = if (photo) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("The gallery refused the file")
        try {
            resolver.openOutputStream(uri)!!.use { sink ->
                File(path).inputStream().use { it.copyTo(sink) }
            }
        } catch (e: Exception) {
            // No half-made entry left in the gallery.
            resolver.delete(uri, null, null)
            throw e
        }
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
    }
}
