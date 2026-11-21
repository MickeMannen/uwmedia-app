package org.christersson.uwmedia

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.opengl.GLES20
import android.opengl.GLUtils
import android.os.Handler
import android.os.Looper
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.ColorLut
import androidx.media3.effect.GlShaderProgram
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Crop
import androidx.media3.effect.Presentation
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.google.common.collect.ImmutableList
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * The phone's media engine on Android (spec §2, §9; owner, 2026-11-13:
 * native engines): a video probed and its frames taken by the platform's
 * retriever, and encoded by Media3 Transformer with the app's colour LUTs
 * (each fading into the next up to its time) and its overlay pictures. One encode at a
 * time; the Dart side asks for its progress and may cancel it.
 */
@UnstableApi
class MediaEngine(private val context: Context) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var transformer: Transformer? = null

    // The encode going on: its answer and its file, for a cancel.
    private var pending: Pair<MethodChannel.Result, String>? = null
    private val progress = ProgressHolder()

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> background(result) { probe(call.argument<String>("path")!!) }
            "frameAt" -> background(result) {
                frameAt(
                    call.argument<String>("path")!!,
                    call.argument<Double>("seconds") ?: 0.0,
                    call.argument<Int>("maxWidth")!!,
                    call.argument<Int>("maxHeight")!!,
                    call.argument<Boolean>("exact") ?: false,
                )
            }
            "encode" -> encode(call, result)
            "progress" -> result.success(currentProgress())
            "cancel" -> {
                // Transformer tells its listener nothing of a cancel.
                transformer?.cancel()
                transformer = null
                pending?.let { (answer, output) ->
                    File(output).delete()
                    answer.error("cancelled", "Stopped", null)
                }
                pending = null
                result.success(null)
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

    private fun probe(path: String): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            fun number(key: Int) = retriever.extractMetadata(key)?.toLongOrNull()
            var width = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
            var height = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
            val rotation = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
            if (rotation == 90 || rotation == 270) {
                width = height.also { height = width }
            }
            val durationMs = number(MediaMetadataRetriever.METADATA_KEY_DURATION) ?: 0L
            val frames = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
            var bitrate = number(MediaMetadataRetriever.METADATA_KEY_BITRATE)
            var fps: Double? = null
            var mime: String? = null
            var hdr = false
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(path)
                for (i in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(i)
                    val type = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (!type.startsWith("video/")) continue
                    mime = type
                    if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                        fps = format.getNumber(MediaFormat.KEY_FRAME_RATE)?.toDouble()
                    }
                    if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
                        // The video stream's own rate first, as Python's probe.
                        bitrate = format.getInteger(MediaFormat.KEY_BIT_RATE).toLong()
                    }
                    if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                        val transfer = format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
                        hdr = transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
                            transfer == MediaFormat.COLOR_TRANSFER_HLG
                    }
                    break
                }
            } finally {
                extractor.release()
            }
            if (mime == null) throw IllegalArgumentException("No video in the file")
            return mapOf(
                "width" to width,
                "height" to height,
                "rotation" to rotation,
                "durationMs" to durationMs,
                "frames" to frames,
                "fps" to fps,
                "bitrate" to bitrate,
                "mime" to mime,
                "hdr" to hdr,
            )
        } finally {
            retriever.release()
        }
    }

    // A frame as RGBA bytes, upright, no bigger than the size asked for.
    // [exact] takes the frame at that time (slow on a 4K clip); otherwise
    // the key frame nearest to it.
    private fun frameAt(
        path: String,
        seconds: Double,
        maxWidth: Int,
        maxHeight: Int,
        exact: Boolean,
    ): Map<String, Any>? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val option = if (exact) {
                MediaMetadataRetriever.OPTION_CLOSEST
            } else {
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            }
            val us = (seconds * 1_000_000).toLong()
            // The upright size, fitted inside the box asked for (never made
            // bigger), so the frame keeps its shape.
            fun number(key: Int) = retriever.extractMetadata(key)?.toIntOrNull() ?: 0
            var width = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            var height = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            val rotation = number(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            if (rotation == 90 || rotation == 270) {
                width = height.also { height = width }
            }
            if (width <= 0 || height <= 0) return null
            val scale = minOf(1.0, maxWidth.toDouble() / width, maxHeight.toDouble() / height)
            val frame = retriever.getScaledFrameAtTime(
                us,
                option,
                maxOf(1, (width * scale).toInt()),
                maxOf(1, (height * scale).toInt()),
            ) ?: return null
            val rgba = if (frame.config == Bitmap.Config.ARGB_8888) {
                frame
            } else {
                frame.copy(Bitmap.Config.ARGB_8888, false).also { frame.recycle() }
            }
            val buffer = ByteBuffer.allocate(rgba.byteCount)
            rgba.copyPixelsToBuffer(buffer)
            val answer = mapOf(
                "width" to rgba.width,
                "height" to rgba.height,
                "rgba" to buffer.array(),
            )
            rgba.recycle()
            return answer
        } finally {
            retriever.release()
        }
    }

    // The app's LUTs as Media3 wants them: N x N² pictures, blue changing
    // fastest along a row, then green, then red down the rows
    // (`SingleColorLut.transformCubeIntoBitmap`). The app's tables have
    // red changing fastest.
    private fun lutBitmap(lut: ByteArray, size: Int): Bitmap {
        val pixels = IntArray(size * size * size)
        for (r in 0 until size) {
            for (g in 0 until size) {
                for (b in 0 until size) {
                    val i = (r + g * size + b * size * size) * 3
                    pixels[b + size * (g + size * r)] = Color.rgb(
                        lut[i].toInt() and 0xFF,
                        lut[i + 1].toInt() and 0xFF,
                        lut[i + 2].toInt() and 0xFF,
                    )
                }
            }
        }
        return Bitmap.createBitmap(pixels, size, size * size, Bitmap.Config.ARGB_8888)
    }

    // The colour LUTs of a clip, each from its start time on (Python's
    // sendcmd list); Media3's own SingleColorLut has only one. Over the
    // last [fadeUs] before a LUT's time the one before turns into it (a
    // mix of the two, in 64 steps, as the iPhone's engine), so that the
    // colour moves from one to the other instead of jumping.
    private class TimedColorLut(
        private val startsUs: LongArray,
        private val bitmaps: List<Bitmap>,
        private val fadeUs: Long,
    ) : ColorLut {
        private var textures = IntArray(0)

        // The texture of a mix, and what it holds: the LUT it starts from
        // and how many 64ths of the next one.
        private var mixTexture = -1
        private var mixBitmap: Bitmap? = null
        private var mixIndex = -1
        private var mixSteps = 0
        private var fromPixels = IntArray(0)
        private var toPixels = IntArray(0)
        private var mixPixels = IntArray(0)
        private var pixelsOf = -1

        private fun indexAt(timeUs: Long): Int {
            var index = 0
            while (index + 1 < startsUs.size && startsUs[index + 1] <= timeUs) index++
            return index
        }

        // How many 64ths of the next LUT the frame at [timeUs] gets.
        private fun stepsAt(index: Int, timeUs: Long): Int {
            if (fadeUs <= 0 || index + 1 >= startsUs.size) return 0
            val end = startsUs[index + 1]
            val start = maxOf(end - fadeUs, startsUs[index])
            if (timeUs <= start || end <= start) return 0
            return ((timeUs - start) * MIX_STEPS / (end - start)).toInt()
        }

        // The mix as a texture; called on the GL thread, as the frames
        // are drawn.
        private fun mixed(index: Int, steps: Int): Int {
            if (index == mixIndex && steps == mixSteps) return mixTexture
            val width = bitmaps[0].width
            val height = bitmaps[0].height
            val count = width * height
            if (pixelsOf != index) {
                if (fromPixels.size != count) {
                    fromPixels = IntArray(count)
                    toPixels = IntArray(count)
                    mixPixels = IntArray(count)
                }
                bitmaps[index].getPixels(fromPixels, 0, width, 0, 0, width, height)
                bitmaps[index + 1].getPixels(toPixels, 0, width, 0, 0, width, height)
                pixelsOf = index
            }
            // Red with blue, and green, each mixed in one go: a colour
            // times 64 fits in the room between them.
            val keep = MIX_STEPS - steps
            for (i in 0 until count) {
                val a = fromPixels[i]
                val b = toPixels[i]
                val redBlue =
                    ((a and 0xFF00FF) * keep + (b and 0xFF00FF) * steps + 0x200020) ushr 6
                val green = ((a and 0xFF00) * keep + (b and 0xFF00) * steps + 0x2000) ushr 6
                mixPixels[i] = (0xFF shl 24) or (redBlue and 0xFF00FF) or (green and 0xFF00)
            }
            val bitmap = mixBitmap ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                .also { mixBitmap = it }
            bitmap.setPixels(mixPixels, 0, width, 0, 0, width, height)
            // The texture the frame's drawing has bound is left as it was.
            val bound = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_TEXTURE_BINDING_2D, bound, 0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, mixTexture)
            GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bitmap)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, bound[0])
            mixIndex = index
            mixSteps = steps
            return mixTexture
        }

        override fun getLutTextureId(presentationTimeUs: Long): Int {
            check(textures.isNotEmpty()) { "The LUTs are not textures yet" }
            val index = indexAt(presentationTimeUs)
            val steps = stepsAt(index, presentationTimeUs)
            return if (steps == 0 || mixTexture == -1) textures[index] else mixed(index, steps)
        }

        override fun getLength(presentationTimeUs: Long): Int = bitmaps[0].width

        override fun release() {
            textures.forEach { GlUtil.deleteTexture(it) }
            textures = IntArray(0)
            if (mixTexture != -1) GlUtil.deleteTexture(mixTexture)
            mixTexture = -1
            mixIndex = -1
            mixBitmap?.recycle()
            mixBitmap = null
        }

        override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
            if (useHdr) {
                throw VideoFrameProcessingException("The colour LUT works on SDR frames only")
            }
            release()
            try {
                textures = IntArray(bitmaps.size) { GlUtil.createTexture(bitmaps[it]) }
                if (fadeUs > 0 && bitmaps.size > 1) {
                    // Written over by each mix.
                    mixTexture = GlUtil.createTexture(bitmaps[0])
                }
            } catch (e: GlUtil.GlException) {
                throw VideoFrameProcessingException("Could not store the LUTs as textures", e)
            }
            return super.toGlShaderProgram(context, useHdr)
        }

        private companion object {
            const val MIX_STEPS = 64
        }
    }

    // One overlay layer: its pictures, each shown from its start time on,
    // with its top-left corner at (x, y) pixels of the frame.
    private class LayerOverlay(
        private val paths: List<String>,
        private val startsUs: LongArray,
        x: Int,
        y: Int,
        frameWidth: Int,
        frameHeight: Int,
    ) : BitmapOverlay() {
        private var shown = -1
        private var bitmap: Bitmap? = null
        private val settings = StaticOverlaySettings.Builder()
            // Anchors run from -1 to 1, y upwards: the picture's top-left
            // corner on the frame's point (x, y).
            .setOverlayFrameAnchor(-1f, 1f)
            .setBackgroundFrameAnchor(
                -1f + 2f * x / frameWidth,
                1f - 2f * y / frameHeight,
            )
            .build()

        override fun getBitmap(presentationTimeUs: Long): Bitmap {
            var index = 0
            while (index + 1 < startsUs.size && startsUs[index + 1] <= presentationTimeUs) index++
            if (index != shown || bitmap == null) {
                bitmap?.recycle()
                bitmap = BitmapFactory.decodeFile(paths[index])
                    ?: throw VideoFrameProcessingException("Could not read ${paths[index]}")
                shown = index
            }
            return bitmap!!
        }

        override fun getOverlaySettings(presentationTimeUs: Long) = settings

        override fun release() {
            super.release()
            bitmap?.recycle()
            bitmap = null
        }
    }

    /** The percent of the encode going on; null when there is none. */
    fun currentProgress(): Int? {
        val running = transformer ?: return null
        return if (running.getProgress(progress) == Transformer.PROGRESS_STATE_AVAILABLE) {
            progress.progress
        } else {
            null
        }
    }

    private fun encode(call: MethodCall, result: MethodChannel.Result) {
        if (transformer != null || pending != null) {
            result.error("busy", "Another video is being written", null)
            return
        }
        // Held from here, so that a second encode is refused at once.
        pending = result to call.argument<String>("output")!!
        worker.execute {
            val composition = try {
                composition(call)
            } catch (e: Exception) {
                main.post {
                    pending = null
                    result.error(e.javaClass.simpleName, e.message, null)
                }
                return@execute
            }
            main.post { start(call, result, composition) }
        }
    }

    // The source with its effects: the LUT pictures (about a megabyte
    // each) made here, off the main thread.
    private fun composition(call: MethodCall): Composition {
        val input = call.argument<String>("input")!!
        val output = call.argument<String>("output")!!
        val frameWidth = call.argument<Int>("frameWidth") ?: 0
        val frameHeight = call.argument<Int>("frameHeight") ?: 0
        File(output).delete()
        val effects = mutableListOf<Effect>()
        // The frame the layers are placed on: the picture, or what the
        // crop leaves of it.
        var layerWidth = frameWidth
        var layerHeight = frameHeight
        val crop = call.argument<Map<String, Any>>("crop")
        if (crop != null && frameWidth > 0 && frameHeight > 0) {
            // A part of the upright picture (a portrait copy for sharing),
            // in the effect's own coordinates: -1 to 1, y upwards.
            val x = (crop["x"] as Number).toFloat()
            val y = (crop["y"] as Number).toFloat()
            val w = (crop["width"] as Number).toFloat()
            val h = (crop["height"] as Number).toFloat()
            effects.add(
                Crop(
                    2f * x / frameWidth - 1f,
                    2f * (x + w) / frameWidth - 1f,
                    1f - 2f * (y + h) / frameHeight,
                    1f - 2f * y / frameHeight,
                ),
            )
            layerWidth = w.toInt()
            layerHeight = h.toInt()
        }
        val luts = call.argument<List<Map<String, Any>>>("luts").orEmpty()
        if (luts.isNotEmpty()) {
            val size = call.argument<Int>("lutSize")!!
            effects.add(
                TimedColorLut(
                    LongArray(luts.size) { ((luts[it]["seconds"] as Number).toDouble() * 1e6).toLong() },
                    luts.map { lutBitmap(it["lut"] as ByteArray, size) },
                    ((call.argument<Number>("lutFade")?.toDouble() ?: 0.0) * 1e6).toLong(),
                ),
            )
        }
        val layers = call.argument<List<Map<String, Any>>>("layers").orEmpty()
        if (layers.isNotEmpty()) {
            val overlays = layers.map { layer ->
                @Suppress("UNCHECKED_CAST")
                val pictures = layer["pictures"] as List<Map<String, Any>>
                LayerOverlay(
                    pictures.map { it["path"] as String },
                    LongArray(pictures.size) { ((pictures[it]["seconds"] as Number).toDouble() * 1e6).toLong() },
                    (layer["x"] as Number).toInt(),
                    (layer["y"] as Number).toInt(),
                    layerWidth,
                    layerHeight,
                ) as TextureOverlay
            }
            effects.add(OverlayEffect(ImmutableList.copyOf(overlays)))
        }
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        if (width != null && height != null) {
            // Scaled to fit and padded, as ffmpeg's scale and pad; after
            // the layers, so that they lie on the picture.
            effects.add(
                Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT),
            )
        }
        // A part of the video only ("start" and "end", seconds); the LUTs'
        // and pictures' times count from its start. Not yet tried on a
        // phone.
        val start = call.argument<Double>("start")
        val end = call.argument<Double>("end")
        val media = MediaItem.Builder().setUri(Uri.fromFile(File(input)))
        if (start != null && end != null && end > start) {
            media.setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs((start * 1000).toLong())
                    .setEndPositionMs((end * 1000).toLong())
                    .build(),
            )
        }
        val item = EditedMediaItem.Builder(media.build())
            .setEffects(Effects(ImmutableList.of(), ImmutableList.copyOf(effects)))
            .build()
        return Composition.Builder(EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item)))
            .apply {
                if (luts.isNotEmpty() || layers.isNotEmpty()) {
                    // The LUT and the overlays work on SDR frames: an HDR
                    // source is turned to SDR (an SDR one is left as it
                    // is), whatever the probe made of it.
                    setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
                }
            }
            .build()
    }

    private fun start(call: MethodCall, result: MethodChannel.Result, composition: Composition) {
        if (pending?.first !== result) {
            // Cancelled while the effects were made.
            return
        }
        val output = call.argument<String>("output")!!
        // HEVC, but H.264 for a copy made for sharing.
        val h264 = call.argument<String>("codec") == "h264"
        val builder = Transformer.Builder(context)
            .setVideoMimeType(if (h264) MimeTypes.VIDEO_H264 else MimeTypes.VIDEO_H265)
            // AAC sound: AAC is copied as it is, anything else (a camera's
            // PCM) encoded, since a phone's player plays no PCM in an MP4
            // and the video seemed to have no sound.
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
        call.argument<Number>("bitrate")?.let { bitrate ->
            builder.setEncoderFactory(
                DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder().setBitrate(bitrate.toInt()).build(),
                    )
                    .build(),
            )
        }
        val started = System.nanoTime()
        val running = builder
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    transformer = null
                    pending = null
                    result.success(
                        mapOf(
                            "ms" to (System.nanoTime() - started) / 1_000_000L,
                            "bytes" to File(output).length(),
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
                    transformer = null
                    pending = null
                    File(output).delete()
                    result.error(
                        "export",
                        "${exportException.errorCodeName}: ${exportException.message}",
                        null,
                    )
                }
            })
            .build()
        transformer = running
        try {
            running.start(composition, output)
        } catch (e: Exception) {
            transformer = null
            pending = null
            result.error(e.javaClass.simpleName, e.message, null)
        }
    }
}
