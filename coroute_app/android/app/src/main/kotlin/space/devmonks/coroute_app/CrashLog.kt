package space.devmonks.coroute_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * 3.55 diagnostics log (docs/features_355/diagnostics_logs.md): native crashes and main-thread
 * stalls written to `files/diag/native_crashes.jsonl`. Dart (DiagLogService) reads that file at
 * the next start, merges each line into the persistent app log and deletes it.
 *
 * Privacy: only the exception class, a scrubbed and shortened message (no e-mails, no long digit
 * runs, at most 160 characters), the thread name and the top 8 frames (class.method(File:line)).
 * Never device ids, never user data. Nothing leaves the phone unless the rider sends the logs.
 *
 * - [install]: once per process, wraps (and then calls) the existing default uncaught-exception
 *   handler, so Android's own crash handling (and any crash reporter) still runs.
 * - [startStallWatch] / [stopStallWatch]: while the app is in front, a tiny watchdog thread posts a
 *   no-op to the main thread every 2 s; when it has not run for 5 s, one "stall" line is written
 *   (ANR-like). Stopped in the background (no cost there).
 */
object CrashLog {
    private const val TAG = "CoRouteDiag"
    private const val FILE = "native_crashes.jsonl"
    private const val MAX_FILE_BYTES = 256 * 1024L
    private const val STALL_MS = 5000L
    private const val PING_MS = 2000L

    @Volatile private var installed = false
    @Volatile private var dir: File? = null

    fun install(context: Context) {
        if (installed) return
        installed = true
        dir = try { File(context.applicationContext.filesDir, "diag").apply { mkdirs() } } catch (e: Exception) { null }
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                write(JSONObject().apply {
                    put("t", System.currentTimeMillis())
                    put("kind", "crash")
                    put("type", error.javaClass.name)
                    put("msg", scrub(error.message))
                    put("thread", thread.name.take(40))
                    put("stack", topFrames(error))
                    val cause = error.cause
                    if (cause != null && cause !== error) {
                        put("cause", cause.javaClass.name)
                        put("causeStack", topFrames(cause))
                    }
                })
            } catch (_: Throwable) {
                // Never in the way of the real crash handling.
            }
            if (previous != null) {
                previous.uncaughtException(thread, error)
            } else {
                android.os.Process.killProcess(android.os.Process.myPid())
                System.exit(10)
            }
        }
    }

    // ------------------------------------------------------------------ stall watch
    @Volatile private var watching = false
    @Volatile private var generation = 0
    private var watcher: Thread? = null
    @Volatile private var lastPong = 0L
    private val main = Handler(Looper.getMainLooper())
    private val pong = Runnable { lastPong = SystemClock.uptimeMillis() }

    fun startStallWatch() {
        if (watching) return
        watching = true
        val myGeneration = ++generation
        lastPong = SystemClock.uptimeMillis()
        val t = Thread({
            var reported = false
            // A quick pause / resume starts a new thread: an older one stops at its next round.
            while (watching && myGeneration == generation) {
                main.post(pong)
                try { Thread.sleep(PING_MS) } catch (_: InterruptedException) { break }
                val late = SystemClock.uptimeMillis() - lastPong
                if (late >= STALL_MS && !reported) {
                    reported = true
                    try {
                        write(JSONObject().apply {
                            put("t", System.currentTimeMillis())
                            put("kind", "stall")
                            put("ms", late)
                            put("stack", mainFrames())
                        })
                    } catch (_: Throwable) {}
                } else if (late < PING_MS * 2) {
                    reported = false // recovered: the next stall is reported again
                }
            }
        }, "coroute-stall-watch")
        t.isDaemon = true
        t.priority = Thread.MIN_PRIORITY
        watcher = t
        t.start()
    }

    fun stopStallWatch() {
        watching = false
        generation++
        watcher?.interrupt()
        watcher = null
        main.removeCallbacks(pong)
    }

    // ------------------------------------------------------------------ helpers
    private fun write(o: JSONObject) {
        val d = dir ?: return
        try {
            val f = File(d, FILE)
            if (f.exists() && f.length() > MAX_FILE_BYTES) return // never grows without bound
            f.appendText(o.toString() + "\n")
        } catch (e: Exception) {
            Log.w(TAG, "crash log not written: ${e.javaClass.simpleName}")
        }
    }

    private fun frameText(e: StackTraceElement): String {
        val cls = e.className.substringAfterLast('.')
        return "$cls.${e.methodName}(${e.fileName ?: "?"}:${e.lineNumber})"
    }

    private fun topFrames(t: Throwable): String = t.stackTrace.take(8).joinToString(" | ") { frameText(it) }

    private fun mainFrames(): String = try {
        Looper.getMainLooper().thread.stackTrace.take(8).joinToString(" | ") { frameText(it) }
    } catch (e: Exception) { "" }

    private val email = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private val digits = Regex("\\d{7,}")
    private val longToken = Regex("[A-Za-z0-9_\\-]{32,}")

    /** Shortened message without e-mails, long numbers or token-like runs. */
    private fun scrub(m: String?): String {
        if (m.isNullOrEmpty()) return ""
        return m.replace(email, "<email>").replace(digits, "<num>").replace(longToken, "<token>")
            .replace('\n', ' ').take(160)
    }
}
