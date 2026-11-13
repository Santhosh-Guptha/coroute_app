package space.devmonks.coroute_app

import android.graphics.Bitmap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * 3.56 "Adjust picture" (MethodChannel "coroute/image"): JPEG encoding for the profile-picture
 * cropper (lib/data/services/avatar_image_codec.dart). Flutter can only write PNG itself, and a PNG
 * photo is about ten times larger than a JPEG.
 *
 * `encodeJpeg {rgba: ByteArray (RGBA_8888, width * height * 4), width, height, quality}` -> ByteArray.
 * The pixels come from the app's own canvas, so the result has no EXIF data at all (no GPS, no
 * camera, no date). Framework APIs only; nothing is written to storage. The work runs off the main
 * thread; the answer is posted back on it.
 */
class ImageEncodeChannel : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "encodeJpeg" -> encodeJpeg(call, result)
            else -> result.notImplemented()
        }
    }

    private fun encodeJpeg(call: MethodCall, result: MethodChannel.Result) {
        val rgba = call.argument<ByteArray>("rgba")
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val quality = (call.argument<Int>("quality") ?: 88).coerceIn(40, 100)
        // 4096 px per side at most: a wrong size can never ask for a huge bitmap.
        if (rgba == null || width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
            rgba.size.toLong() != width.toLong() * height.toLong() * 4L) {
            result.error("bad_args", "rgba must hold width * height * 4 bytes", null)
            return
        }
        worker.execute {
            var bitmap: Bitmap? = null
            try {
                val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap = bmp
                // ARGB_8888 bitmaps store their bytes in R, G, B, A order, the order Flutter gives.
                bmp.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
                val out = ByteArrayOutputStream(width * height / 4)
                val ok = bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)
                val bytes = out.toByteArray()
                main.post { if (ok) result.success(bytes) else result.error("encode_failed", "JPEG encoding failed", null) }
            } catch (t: Throwable) {
                main.post { result.error("encode_failed", t.javaClass.simpleName, null) }
            } finally {
                bitmap?.recycle()
            }
        }
    }
}
