package space.devmonks.coroute_app

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * Round 8 intercom Opus codec on the platform MediaCodec (channel "coroute/voice_codec"); see
 * docs/features_355/voice_clarity.md. Dart side: lib/data/services/voice/voice_codec.dart.
 *
 * - Encoder: Android 10+ (API 29, the platform "c2.android.opus.encoder"), 16 kHz mono PCM16 in,
 *   one Opus packet per 20 ms out. Bitrate from Dart (24 kbit/s, 16 kbit/s in data saver), VBR when the
 *   encoder reports it, complexity 5 (or the encoder's range). MediaCodec has no public key for Opus in-band
 *   FEC or DTX, so none is set: the voice gate already sends nothing in silence (DTX-like) and the receiver
 *   conceals lost frames (lib/domain/audio/voice_jitter.dart).
 * - Decoder: Android 5+ (API 21). Configured with an OpusHead (csd-0), pre-skip (csd-1) and seek pre-roll
 *   (csd-2), as MediaExtractor would. The platform decoder outputs 48 kHz; it is decimated to the rate Dart
 *   asked for (16 kHz: 3:1 windowed-sinc FIR; anything else: linear).
 * - All MediaCodec work runs on one worker thread (codecs are not thread-safe); replies go back on the main
 *   thread in call order. Every failure is answered with null / empty, never an exception into Dart, and Dart
 *   then uses PCM16 (the 3.55 path).
 *
 * Not compiled in the build sandbox (no Android SDK there): build once and run device QA (ROUND8_VOICE_NOTES.md).
 */
class VoiceCodecChannel : MethodChannel.MethodCallHandler {
    private val thread = HandlerThread("coroute-voice-codec").apply { start() }
    private val worker = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private val encoders = HashMap<Int, OpusEncoder>()
    private val decoders = HashMap<Int, OpusDecoder>()
    private var nextId = 1
    private var capsCache: Map<String, Any>? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val method = call.method
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        worker.post {
            val reply: Any? = try {
                handle(method, args)
            } catch (t: Throwable) {
                Log.w(TAG, "voice codec $method failed: ${t.javaClass.simpleName}")
                null
            }
            main.post {
                if (reply === NOT_IMPLEMENTED) result.notImplemented() else result.success(reply)
            }
        }
    }

    private fun handle(method: String, a: Map<*, *>): Any? = when (method) {
        "caps" -> caps()
        "encOpen" -> {
            val enc = OpusEncoder((a["sampleRate"] as? Int) ?: 16000, (a["bitrate"] as? Int) ?: 24000)
            val id = nextId++
            encoders[id] = enc
            id
        }
        "encode" -> {
            val enc = encoders[(a["id"] as? Int) ?: -1]
            val pcm = a["pcm"] as? ByteArray
            if (enc == null || pcm == null) emptyList<ByteArray>() else enc.encode(pcm)
        }
        "encClose" -> {
            encoders.remove((a["id"] as? Int) ?: -1)?.release()
            true
        }
        "decOpen" -> {
            val dec = OpusDecoder((a["sampleRate"] as? Int) ?: 16000)
            val id = nextId++
            decoders[id] = dec
            id
        }
        "decode" -> {
            val dec = decoders[(a["id"] as? Int) ?: -1]
            @Suppress("UNCHECKED_CAST")
            val packets = (a["packets"] as? List<Any?>)?.mapNotNull { it as? ByteArray } ?: emptyList()
            dec?.decode(packets)
        }
        "decReset" -> {
            decoders[(a["id"] as? Int) ?: -1]?.reset()
            true
        }
        "decClose" -> {
            decoders.remove((a["id"] as? Int) ?: -1)?.release()
            true
        }
        else -> NOT_IMPLEMENTED
    }

    private fun caps(): Map<String, Any> {
        capsCache?.let { return it }
        var enc = false
        var dec = false
        try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val f = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, 16000, 1)
            enc = Build.VERSION.SDK_INT >= 29 && list.findEncoderForFormat(f) != null
            val d = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, 48000, 1)
            dec = list.findDecoderForFormat(d) != null
        } catch (t: Throwable) {
            Log.w(TAG, "voice codec caps: ${t.javaClass.simpleName}")
        }
        val c = mapOf("encoder" to enc, "decoder" to dec, "sdk" to Build.VERSION.SDK_INT)
        capsCache = c
        return c
    }

    fun dispose() {
        worker.post {
            encoders.values.forEach { it.release() }
            decoders.values.forEach { it.release() }
            encoders.clear()
            decoders.clear()
            thread.quitSafely()
        }
    }

    // ------------------------------------------------------------------ encoder
    private class OpusEncoder(private val sampleRate: Int, bitrate: Int) {
        private val codec: MediaCodec
        private val info = MediaCodec.BufferInfo()
        private var ptsUs = 0L

        init {
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, sampleRate, 1)
            fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4096)
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(fmt)
                ?: throw IllegalStateException("no Opus encoder")
            val c = MediaCodec.createByCodecName(name)
            try {
                val caps = c.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_AUDIO_OPUS).encoderCapabilities
                if (caps?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR) == true) {
                    fmt.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                }
                caps?.complexityRange?.let { cr ->
                    fmt.setInteger(MediaFormat.KEY_COMPLEXITY, 5.coerceIn(cr.lower, cr.upper))
                }
                c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                c.start()
            } catch (t: Throwable) {
                c.release()
                throw t
            }
            codec = c
        }

        /** PCM16 mono (any length) in, the Opus packets that came out (0..n, 20 ms each). */
        fun encode(pcm: ByteArray): List<ByteArray> {
            var off = 0
            while (off < pcm.size) {
                val idx = codec.dequeueInputBuffer(10_000)
                if (idx < 0) break // encoder stalled: drop the rest of this frame rather than block the talk
                val buf = codec.getInputBuffer(idx) ?: break
                buf.clear()
                val n = min(buf.remaining(), pcm.size - off) and 1.inv()
                if (n <= 0) {
                    codec.queueInputBuffer(idx, 0, 0, ptsUs, 0)
                    break
                }
                buf.put(pcm, off, n)
                codec.queueInputBuffer(idx, 0, n, ptsUs, 0)
                ptsUs += (n / 2) * 1_000_000L / sampleRate
                off += n
            }
            val out = ArrayList<ByteArray>(2)
            while (true) {
                val o = codec.dequeueOutputBuffer(info, 2_000)
                if (o < 0) {
                    if (o == MediaCodec.INFO_TRY_AGAIN_LATER) break
                    continue // format / buffers changed
                }
                val ob = codec.getOutputBuffer(o)
                val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                if (ob != null && info.size > 0 && !config) {
                    ob.position(info.offset)
                    ob.limit(info.offset + info.size)
                    val p = ByteArray(info.size)
                    ob.get(p)
                    out.add(p)
                }
                codec.releaseOutputBuffer(o, false)
            }
            return out
        }

        fun release() {
            try { codec.stop() } catch (_: Throwable) {}
            try { codec.release() } catch (_: Throwable) {}
        }
    }

    // ------------------------------------------------------------------ decoder
    private class OpusDecoder(private val outRate: Int) {
        private val codec: MediaCodec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
        private val info = MediaCodec.BufferInfo()
        private var ptsUs = 0L
        private var codecRate = 48000
        private val down = Decimator3()

        init {
            try {
                val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, 48000, 1)
                val head = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
                head.put("OpusHead".toByteArray(Charsets.US_ASCII))
                head.put(1.toByte()) // version
                head.put(1.toByte()) // channels
                head.putShort(PRE_SKIP.toShort())
                head.putInt(16000) // original input rate (informational)
                head.putShort(0) // output gain
                head.put(0.toByte()) // mapping family 0 (mono / stereo)
                head.flip()
                fmt.setByteBuffer("csd-0", head)
                fmt.setByteBuffer("csd-1", nsBuffer(PRE_SKIP * 1_000_000_000L / 48000))
                fmt.setByteBuffer("csd-2", nsBuffer(80_000_000L))
                codec.configure(fmt, null, null, 0)
                codec.start()
            } catch (t: Throwable) {
                codec.release()
                throw t
            }
        }

        private fun nsBuffer(ns: Long): ByteBuffer {
            val b = ByteBuffer.allocate(8).order(ByteOrder.nativeOrder())
            b.putLong(ns)
            b.flip()
            return b
        }

        /** Opus packets of one frame in, PCM16 at [outRate] out (empty when nothing decoded). */
        fun decode(packets: List<ByteArray>): ByteArray {
            val pcm = java.io.ByteArrayOutputStream(packets.size * 2 * outRate / 50)
            var pending = 0
            for (p in packets) {
                val idx = codec.dequeueInputBuffer(10_000)
                if (idx < 0) continue
                val buf = codec.getInputBuffer(idx) ?: continue
                buf.clear()
                if (p.size > buf.remaining()) { codec.queueInputBuffer(idx, 0, 0, ptsUs, 0); continue }
                buf.put(p)
                codec.queueInputBuffer(idx, 0, p.size, ptsUs, 0)
                ptsUs += 20_000
                pending++
                drainInto(pcm, 0)
            }
            // The soft decoder answers within a millisecond; wait a little for the last packet's output.
            var tries = 0
            while (pending > 0 && pcm.size() == 0 && tries++ < 4) drainInto(pcm, 5_000)
            return pcm.toByteArray()
        }

        private fun drainInto(sink: java.io.ByteArrayOutputStream, timeoutUs: Long) {
            while (true) {
                val o = codec.dequeueOutputBuffer(info, timeoutUs)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    codecRate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    continue
                }
                if (o < 0) return
                val ob = codec.getOutputBuffer(o)
                if (ob != null && info.size > 0) {
                    ob.position(info.offset)
                    ob.limit(info.offset + info.size)
                    val raw = ShortArray(info.size / 2)
                    ob.order(ByteOrder.nativeOrder()).asShortBuffer().get(raw)
                    val res = resample(raw)
                    val bytes = ByteBuffer.allocate(res.size * 2).order(ByteOrder.LITTLE_ENDIAN)
                    bytes.asShortBuffer().put(res)
                    sink.write(bytes.array())
                }
                codec.releaseOutputBuffer(o, false)
            }
        }

        private fun resample(x: ShortArray): ShortArray {
            if (codecRate == outRate) return x
            if (codecRate == outRate * 3) return down.process(x)
            // Generic linear interpolation (not expected with the platform decoder).
            val n = (x.size.toLong() * outRate / codecRate).toInt()
            val out = ShortArray(n)
            for (i in 0 until n) {
                val pos = i.toDouble() * codecRate / outRate
                val k = pos.toInt()
                val f = pos - k
                val a = x[min(k, x.size - 1)].toDouble()
                val b = x[min(k + 1, x.size - 1)].toDouble()
                out[i] = (a + (b - a) * f).toInt().coerceIn(-32768, 32767).toShort()
            }
            return out
        }

        /** New stream (another speaker): drops the old stream's decoder state. */
        fun reset() {
            try { codec.flush() } catch (_: Throwable) {}
            down.reset()
        }

        fun release() {
            try { codec.stop() } catch (_: Throwable) {}
            try { codec.release() } catch (_: Throwable) {}
        }
    }

    /** 48 -> 16 kHz: 63-tap Kaiser-ish (Blackman) windowed sinc, cut-off 7.2 kHz, keeps every 3rd sample. */
    private class Decimator3 {
        private val taps = 63
        private val h = FloatArray(taps)
        private val hist = FloatArray(taps)
        private var phase = 0

        init {
            val mid = (taps - 1) / 2
            val fc = 7200.0 / 48000.0
            var sum = 0.0
            for (i in 0 until taps) {
                val k = i - mid
                val s = if (k == 0) 2 * fc else sin(2 * PI * fc * k) / (PI * k)
                val w = 0.42 - 0.5 * cos(2 * PI * i / (taps - 1)) + 0.08 * cos(4 * PI * i / (taps - 1))
                h[i] = (s * w).toFloat()
                sum += s * w
            }
            for (i in 0 until taps) h[i] = (h[i] / sum).toFloat()
        }

        fun process(x: ShortArray): ShortArray {
            val out = ShortArray((x.size + phase) / 3 + 1)
            var n = 0
            for (s in x) {
                System.arraycopy(hist, 0, hist, 1, taps - 1)
                hist[0] = s.toFloat()
                if (phase == 0) {
                    var acc = 0f
                    for (j in 0 until taps) acc += h[j] * hist[j]
                    out[n++] = acc.toInt().coerceIn(-32768, 32767).toShort()
                }
                phase = (phase + 1) % 3
            }
            return out.copyOf(n)
        }

        fun reset() {
            hist.fill(0f)
            phase = 0
        }
    }

    companion object {
        private const val TAG = "CoRouteVoice"
        private const val PRE_SKIP = 312 // 6.5 ms at 48 kHz (the Opus encoder's look-ahead)
        private val NOT_IMPLEMENTED = Any()
    }
}
