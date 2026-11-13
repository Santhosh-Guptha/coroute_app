package space.devmonks.coroute_app

import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Round 10 offline link: MethodChannel "coroute/mesh_ble" + EventChannel "coroute/mesh_ble_events" for
 * [LongRangeBle]. Dart side: lib/data/services/offline_link/mesh_ble_platform.dart.
 *
 * Methods: caps -> map; start {tag} -> L2CAP PSM (0 = none / failed); setBeacon {beacon: 13 bytes};
 * setDuty {scan: off|lowPower|balanced|lowLatency, advMs, txHigh}; connect {addr, psm, coded}; disconnect {addr};
 * send {data} -> number of links; links -> count; stop.
 * Events: {t: beacon|frame|link|rssi|state|error, ...} (see LongRangeBle). Everything is a no-op without Bluetooth
 * LE hardware, with the adapter off or without the runtime permissions (caps tells Dart which).
 */
class MeshBleChannel(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private val ble = LongRangeBle(context) { e -> sink?.success(e) }
    private var receiver: BroadcastReceiver? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "caps" -> result.success(ble.caps())
                "start" -> result.success(ble.start(call.argument<Int>("tag") ?: -1))
                "setBeacon" -> {
                    val b = call.argument<ByteArray>("beacon")
                    if (b != null) ble.setBeacon(b)
                    result.success(null)
                }
                "setDuty" -> {
                    ble.setDuty(call.argument<String>("scan") ?: "off", call.argument<Int>("advMs") ?: 0, call.argument<Boolean>("txHigh") ?: true)
                    result.success(null)
                }
                "connect" -> {
                    val addr = call.argument<String>("addr")
                    if (addr != null) ble.connect(addr, call.argument<Int>("psm") ?: 0, call.argument<Boolean>("coded") ?: false)
                    result.success(null)
                }
                "disconnect" -> {
                    call.argument<String>("addr")?.let { ble.disconnect(it) }
                    result.success(null)
                }
                "send" -> {
                    val d = call.argument<ByteArray>("data")
                    result.success(if (d == null) 0 else ble.send(d))
                }
                "links" -> result.success(ble.linkCount())
                "stop" -> {
                    ble.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            // Never crash the app over the offline link: Dart treats an error as "not available".
            result.error("mesh_ble", e.message ?: e.javaClass.simpleName, null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (receiver == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, intent: Intent?) {
                    val state = intent?.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR) ?: return
                    if (state == BluetoothAdapter.STATE_OFF) ble.stop()
                    sink?.success(mapOf("t" to "state", "enabled" to (state == BluetoothAdapter.STATE_ON)))
                }
            }
            try {
                val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
                if (Build.VERSION.SDK_INT >= 33) {
                    context.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    context.registerReceiver(r, filter)
                }
                receiver = r
            } catch (_: Throwable) {
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun dispose() {
        sink = null
        receiver?.let { try { context.unregisterReceiver(it) } catch (_: Throwable) {} }
        receiver = null
        ble.dispose()
    }
}
