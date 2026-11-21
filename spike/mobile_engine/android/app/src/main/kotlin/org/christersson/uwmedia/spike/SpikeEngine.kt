package org.christersson.uwmedia.spike

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.SingleColorLut
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.google.common.collect.ImmutableList
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/** The spike's media engine on Android: Media3 Transformer and the platform's retriever. */
@UnstableApi
class SpikeEngine(private val context: Context) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> result.success(
                mapOf(
                    "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                    "system" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                ),
            )
            "videoInfo" -> background(result) { videoInfo(call.argument<String>("path")!!) }
            "frameAt" -> background(result) {
                frameAt(call.argument<String>("path")!!, call.argument<Double>("seconds") ?: 0.0)
            }
            "transcode" -> transcode(call, result)
            "saveToAlbum" -> background(result) {
                saveToAlbum(call.argument<String>("path")!!, call.argument<String>("album")!!)
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error(e.javaClass.simpleName, e.message, null) }
            }
        }
    }

    private fun videoInfo(path: String): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            var width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
            var height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
            if (rotation == 90 || rotation == 270) {
                width = height.also { height = width }
            }
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
            var fps: Double? = null
            var mime: String? = null
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(path)
                for (i in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(i)
                    val type = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (type.startsWith("video/")) {
                        mime = type
                        if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                            fps = format.getNumber(MediaFormat.KEY_FRAME_RATE)?.toDouble()
                        }
                        break
                    }
                }
            } finally {
                extractor.release()
            }
            return mapOf(
                "width" to width,
                "height" to height,
                "rotation" to rotation,
                "durationMs" to duration,
                "fps" to fps,
                "mime" to mime,
            )
        } finally {
            retriever.release()
        }
    }

    private fun frameAt(path: String, seconds: Double): ByteArray {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val us = (seconds * 1_000_000).toLong()
            val frame = retriever.getScaledFrameAtTime(
                us, MediaMetadataRetriever.OPTION_CLOSEST, 1920, 1920,
            ) ?: throw IllegalStateException("No frame at $seconds s")
            val out = ByteArrayOutputStream()
            frame.compress(Bitmap.CompressFormat.PNG, 100, out)
            frame.recycle()
            return out.toByteArray()
        } finally {
            retriever.release()
        }
    }

    // One overlay picture a second, read once, placed at the bottom left.
    private class SequenceOverlay(
        private val dir: String,
        private val count: Int,
        private val x: Float,
        private val y: Float,
    ) : BitmapOverlay() {
        private var shown = -1
        private var bitmap: Bitmap? = null

        override fun getBitmap(presentationTimeUs: Long): Bitmap {
            val index = (presentationTimeUs / 1_000_000L).toInt().coerceIn(0, count - 1)
            if (index != shown || bitmap == null) {
                bitmap?.recycle()
                bitmap = BitmapFactory.decodeFile(File(dir, "o_%05d.png".format(index)).path)
                shown = index
            }
            return bitmap!!
        }

        override fun getOverlaySettings(presentationTimeUs: Long) =
            StaticOverlaySettings.Builder()
                // The overlay's bottom-left corner on the frame's, moved in:
                // anchors run from -1 to 1.
                .setOverlayFrameAnchor(-1f, -1f)
                .setBackgroundFrameAnchor(-1f + 2f * x, -1f + 2f * y)
                .build()
    }

    private fun transcode(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        val out = call.argument<String>("out")!!
        File(out).delete()
        val effects = mutableListOf<androidx.media3.common.Effect>()
        call.argument<Int>("height")?.let { effects.add(Presentation.createForHeight(it)) }
        call.argument<ByteArray>("lut")?.let { lut ->
            val size = call.argument<Int>("lutSize")!!
            // The app's LUT has red changing fastest; Media3 wants [r][g][b].
            val cube = Array(size) { r ->
                Array(size) { g ->
                    IntArray(size) { b ->
                        val i = (r + g * size + b * size * size) * 3
                        Color.rgb(
                            lut[i].toInt() and 0xFF,
                            lut[i + 1].toInt() and 0xFF,
                            lut[i + 2].toInt() and 0xFF,
                        )
                    }
                }
            }
            effects.add(SingleColorLut.createFromCube(cube))
        }
        call.argument<String>("overlayDir")?.let { dir ->
            val overlay = SequenceOverlay(
                dir,
                call.argument<Int>("overlayCount")!!,
                (call.argument<Double>("overlayX") ?: 0.04).toFloat(),
                (call.argument<Double>("overlayY") ?: 0.04).toFloat(),
            )
            effects.add(OverlayEffect(ImmutableList.of<androidx.media3.effect.TextureOverlay>(overlay)))
        }
        val item = EditedMediaItem.Builder(MediaItem.fromUri(android.net.Uri.fromFile(File(path))))
            .setEffects(Effects(ImmutableList.of(), ImmutableList.copyOf(effects)))
            .build()
        val started = System.nanoTime()
        val transformer = Transformer.Builder(context)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    result.success(
                        mapOf(
                            "ms" to ((System.nanoTime() - started) / 1_000_000L).toInt(),
                            "bytes" to File(out).length(),
                            "mime" to exportResult.videoMimeType,
                            "encoder" to exportResult.videoEncoderName,
                        ),
                    )
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    result.error(
                        "export",
                        "${exportException.errorCodeName}: ${exportException.message}",
                        null,
                    )
                }
            })
            .build()
        transformer.start(item, out)
    }

    private fun saveToAlbum(path: String, album: String) {
        val name = File(path).name
        val extension = name.substringAfterLast('.', "").lowercase()
        val photo = extension in setOf("jpg", "jpeg", "heic", "heif", "png")
        val mime = when (extension) {
            "jpg", "jpeg" -> "image/jpeg"
            "heic", "heif" -> "image/heic"
            "png" -> "image/png"
            else -> "video/mp4"
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            // The folder is the album in the phone's gallery.
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
        resolver.openOutputStream(uri)!!.use { sink -> File(path).inputStream().use { it.copyTo(sink) } }
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
    }
}
