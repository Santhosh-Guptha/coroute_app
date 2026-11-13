package space.devmonks.coroute_app

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Round 10 offline link: Bluetooth LE Long Range (Coded PHY) radio for the rider mesh
 * (docs/features_355/offline_long_range_link.md). Driven from Dart through [MeshBleChannel]; all routing,
 * crypto and policy live in Dart (lib/domain/mesh, lib/data/services/offline_link). This class only moves bytes.
 *
 *  Discovery  a 13-byte beacon (group tag, rider id, seq, caps, L2CAP PSM, MAC) as service data under [SERVICE_UUID]:
 *             - phones with Coded PHY + extended advertising: an extended, connectable advertising set on
 *               PHY_LE_CODED (primary and secondary), plus a slower legacy set so phones WITHOUT Coded PHY still
 *               find them;
 *             - other phones: legacy advertising on 1M (UUID in the advertisement, beacon in the scan response).
 *             Scanning: ScanSettings.setLegacy(false) + PHY_LE_ALL_SUPPORTED (API 26+), hardware filters on the
 *             service UUID / service data so screen-off scanning keeps working (unfiltered scans pause screen-off).
 *  Data       one link per peer: GATT (write-without-response + notify, MTU 247, fragmented) on every API level,
 *             opened with connectGatt(..., PHY_LE_CODED_MASK) when both phones support it (API 26+) and
 *             setPreferredPhy(CODED, S8); on API 29+ an insecure L2CAP CoC channel is opened over the same link
 *             (createInsecureL2capChannel / listenUsingInsecureL2capChannel) and preferred for data. The frames
 *             are already authenticated and encrypted in Dart (AES-256-GCM, per-ride key), hence "insecure"
 *             (no pairing prompts on a motorcycle).
 *  RSSI       every beacon carries the scan RSSI; connected GATT client links also read the remote RSSI every 2 s.
 *
 * Missing hardware or permissions never throw: [caps] says what works and every call is guarded (API level,
 * adapter on, runtime permission, SecurityException).
 */
@SuppressLint("MissingPermission") // every radio call is preceded by hasScan / hasAdvertise / hasConnect
class LongRangeBle(private val context: Context, private val emit: (Map<String, Any?>) -> Unit) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("7c1f0a3e-5b2d-4c8e-9a61-2f4b8d0e6c35")
        val DATA_UUID: UUID = UUID.fromString("7c1f0a3e-5b2d-4c8e-9a61-2f4b8d0e6c36")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val BEACON_LEN = 13
        const val MAX_FRAME = 2048
        private const val RSSI_POLL_MS = 2000L
        private const val SCAN_RESTART_MIN_MS = 6500L // Android refuses more than 5 scan starts per 30 s
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = manager?.adapter
    private val io: ExecutorService = Executors.newCachedThreadPool()

    @Volatile private var running = false
    private var beacon: ByteArray? = null
    private var scanMode = "off"
    private var advIntervalMs = 0
    private var txHigh = true
    private var groupTag = -1

    private var advSetCoded: AdvertisingSet? = null
    private var advSetCodedCallback: AdvertisingSetCallback? = null
    private var legacyAdvCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private var lastScanStart = 0L
    private var gattServer: BluetoothGattServer? = null
    private var l2capServer: BluetoothServerSocket? = null
    @Volatile var psm: Int = 0
        private set

    /** Peer address -> link. */
    private val links = ConcurrentHashMap<String, Link>()

    private inner class Link(val address: String) {
        var gatt: BluetoothGatt? = null // we are the GATT client
        var serverDevice: BluetoothDevice? = null // the peer is our GATT client (notifications go to it)
        var serverSubscribed = false
        var dataChar: BluetoothGattCharacteristic? = null
        var mtu = 23
        var l2cap: BluetoothSocket? = null
        var l2capOut: OutputStream? = null
        val writer: ExecutorService = Executors.newSingleThreadExecutor()
        val gattQueue = ArrayDeque<ByteArray>()
        var gattBusy = false
        var txCounter = 0
        val rx = java.io.ByteArrayOutputStream()
        var rxCounter = -1
        var announced = false
        var phy = 1
        fun via(): String = if (l2cap != null) "l2cap" else "gatt"
        fun ready(): Boolean = l2capOut != null || (gatt != null && dataChar != null) || (serverDevice != null && serverSubscribed)
    }

    // ---------------------------------------------------------------------------------------------- capabilities
    fun hasScan(): Boolean = if (Build.VERSION.SDK_INT >= 31) granted(Manifest.permission.BLUETOOTH_SCAN) else granted(Manifest.permission.ACCESS_FINE_LOCATION)
    fun hasAdvertise(): Boolean = if (Build.VERSION.SDK_INT >= 31) granted(Manifest.permission.BLUETOOTH_ADVERTISE) else true
    fun hasConnect(): Boolean = if (Build.VERSION.SDK_INT >= 31) granted(Manifest.permission.BLUETOOTH_CONNECT) else true
    private fun granted(p: String): Boolean = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    fun caps(): Map<String, Any?> {
        val a = adapter
        val ble = context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        var coded = false
        var extended = false
        var le2m = false
        var maxAdv = 31
        if (a != null && Build.VERSION.SDK_INT >= 26) {
            try {
                coded = a.isLeCodedPhySupported
                extended = a.isLeExtendedAdvertisingSupported
                le2m = a.isLe2MPhySupported
                maxAdv = a.leMaximumAdvertisingDataLength
            } catch (_: Throwable) {
            }
        }
        val enabled = try { a?.isEnabled == true } catch (_: Throwable) { false }
        return mapOf(
            "available" to (a != null && ble),
            "enabled" to enabled,
            "coded" to coded,
            "extended" to extended,
            "le2m" to le2m,
            "l2cap" to (Build.VERSION.SDK_INT >= 29),
            "maxAdvData" to maxAdv,
            "scanPermission" to hasScan(),
            "advertisePermission" to hasAdvertise(),
            "connectPermission" to hasConnect(),
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    private fun codedOk(): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        val a = adapter ?: return false
        return try {
            a.isLeCodedPhySupported && a.isLeExtendedAdvertisingSupported
        } catch (_: Throwable) {
            false
        }
    }

    // -------------------------------------------------------------------------------------------------- start/stop
    /** Opens the data servers (GATT; L2CAP on API 29+). Returns the L2CAP PSM (0 = none) for the beacon. */
    fun start(tag: Int): Int {
        groupTag = tag
        val a = adapter ?: return 0
        if (!a.isEnabled || !hasConnect()) return 0
        running = true
        openGattServer()
        if (Build.VERSION.SDK_INT >= 29 && l2capServer == null) {
            try {
                val server = a.listenUsingInsecureL2capChannel()
                l2capServer = server
                psm = server.psm
                io.execute { acceptLoop(server) }
            } catch (e: Throwable) {
                psm = 0
                emitError("l2cap_listen", e)
            }
        }
        return psm
    }

    fun stop() {
        running = false
        stopAdvertising()
        stopScan()
        // Forget the applied settings so the next start + setDuty / setBeacon applies them again.
        scanMode = "off"
        advIntervalMs = 0
        beacon = null
        for (l in links.values) closeLink(l, notify = false)
        links.clear()
        try { l2capServer?.close() } catch (_: Throwable) {}
        l2capServer = null
        psm = 0
        try { gattServer?.close() } catch (_: Throwable) {}
        gattServer = null
        main.removeCallbacks(rssiPoll)
    }

    fun dispose() {
        stop()
        io.shutdownNow()
    }

    // ------------------------------------------------------------------------------------------------ advertising
    fun setBeacon(b: ByteArray) {
        if (b.size != BEACON_LEN) return
        beacon = b
        if (running) restartAdvertising()
    }

    fun setDuty(scan: String, advMs: Int, high: Boolean) {
        val advChanged = advMs != advIntervalMs || high != txHigh
        advIntervalMs = advMs
        txHigh = high
        if (advChanged && running) restartAdvertising()
        if (scan != scanMode) {
            scanMode = scan
            if (running) restartScan()
        }
    }

    private fun restartAdvertising() {
        stopAdvertising()
        val b = beacon ?: return
        val adv = adapter?.bluetoothLeAdvertiser ?: return
        if (advIntervalMs <= 0 || !hasAdvertise() || adapter?.isEnabled != true) return
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(ParcelUuid(SERVICE_UUID), b)
            .build()
        if (codedOk() && Build.VERSION.SDK_INT >= 26) {
            try {
                val units = (advIntervalMs / 0.625).toInt().coerceIn(AdvertisingSetParameters.INTERVAL_LOW, AdvertisingSetParameters.INTERVAL_HIGH)
                val params = AdvertisingSetParameters.Builder()
                    .setLegacyMode(false)
                    .setConnectable(true)
                    .setScannable(false)
                    .setInterval(units)
                    .setTxPowerLevel(if (txHigh) AdvertisingSetParameters.TX_POWER_HIGH else AdvertisingSetParameters.TX_POWER_MEDIUM)
                    .setPrimaryPhy(BluetoothDevice.PHY_LE_CODED)
                    .setSecondaryPhy(BluetoothDevice.PHY_LE_CODED)
                    .build()
                val cb = object : AdvertisingSetCallback() {
                    override fun onAdvertisingSetStarted(advertisingSet: AdvertisingSet?, txPower: Int, status: Int) {
                        if (status == ADVERTISE_SUCCESS) advSetCoded = advertisingSet else emit(mapOf("t" to "error", "what" to "adv_coded", "code" to status))
                    }
                }
                advSetCodedCallback = cb
                adv.startAdvertisingSet(params, data, null, null, null, cb)
            } catch (e: Throwable) {
                emitError("adv_coded", e)
            }
        }
        // Legacy 1M advertising for phones without Coded PHY (and for this phone when it has none): UUID in the
        // advertisement, beacon in the scan response (31 bytes each). Slower when the coded set is also running.
        try {
            val legacyMs = if (codedOk()) maxOf(advIntervalMs * 2, 500) else advIntervalMs
            val mode = when {
                legacyMs <= 150 -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                legacyMs <= 400 -> AdvertiseSettings.ADVERTISE_MODE_BALANCED
                else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
            }
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(mode)
                .setTxPowerLevel(if (txHigh) AdvertiseSettings.ADVERTISE_TX_POWER_HIGH else AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .setTimeout(0)
                .build()
            val head = AdvertiseData.Builder().setIncludeDeviceName(false).addServiceUuid(ParcelUuid(SERVICE_UUID)).build()
            val cb = object : AdvertiseCallback() {
                override fun onStartFailure(errorCode: Int) {
                    emit(mapOf("t" to "error", "what" to "adv_legacy", "code" to errorCode))
                }
            }
            legacyAdvCallback = cb
            adv.startAdvertising(settings, head, data, cb)
        } catch (e: Throwable) {
            emitError("adv_legacy", e)
        }
    }

    private fun stopAdvertising() {
        val adv = try { adapter?.bluetoothLeAdvertiser } catch (_: Throwable) { null }
        if (adv != null && hasAdvertise()) {
            try {
                if (Build.VERSION.SDK_INT >= 26) advSetCodedCallback?.let { adv.stopAdvertisingSet(it) }
            } catch (_: Throwable) {
            }
            try { legacyAdvCallback?.let { adv.stopAdvertising(it) } } catch (_: Throwable) {}
        }
        advSetCoded = null
        advSetCodedCallback = null
        legacyAdvCallback = null
    }

    // --------------------------------------------------------------------------------------------------- scanning
    private fun restartScan() {
        stopScan()
        if (scanMode == "off" || !hasScan() || adapter?.isEnabled != true) return
        val scanner = adapter?.bluetoothLeScanner ?: return
        val wait = lastScanStart + SCAN_RESTART_MIN_MS - SystemClock.elapsedRealtime()
        if (wait > 0) {
            main.postDelayed({ if (running && scanCallback == null) restartScan() }, wait)
            return
        }
        val mode = when (scanMode) {
            "lowLatency" -> ScanSettings.SCAN_MODE_LOW_LATENCY
            "balanced" -> ScanSettings.SCAN_MODE_BALANCED
            else -> ScanSettings.SCAN_MODE_LOW_POWER
        }
        val sb = ScanSettings.Builder()
            .setScanMode(mode)
            .setReportDelay(0)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
        if (Build.VERSION.SDK_INT >= 26) {
            sb.setLegacy(false)
            sb.setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
        }
        val filters = mutableListOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
        if (groupTag >= 0) {
            filters.add(
                ScanFilter.Builder()
                    .setServiceData(ParcelUuid(SERVICE_UUID), byteArrayOf((groupTag shr 8).toByte(), groupTag.toByte()), byteArrayOf(0xff.toByte(), 0xff.toByte()))
                    .build(),
            )
        }
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) = onResult(result)
            override fun onBatchScanResults(results: MutableList<ScanResult>) { for (r in results) onResult(r) }
            override fun onScanFailed(errorCode: Int) {
                scanCallback = null
                emit(mapOf("t" to "error", "what" to "scan", "code" to errorCode))
            }
        }
        try {
            scanner.startScan(filters, sb.build(), cb)
            scanCallback = cb
            lastScanStart = SystemClock.elapsedRealtime()
        } catch (e: Throwable) {
            emitError("scan", e)
        }
    }

    private fun stopScan() {
        val cb = scanCallback ?: return
        scanCallback = null
        try {
            if (hasScan()) adapter?.bluetoothLeScanner?.stopScan(cb)
        } catch (_: Throwable) {
        }
    }

    private fun onResult(r: ScanResult) {
        val data = r.scanRecord?.getServiceData(ParcelUuid(SERVICE_UUID)) ?: return
        if (data.size < BEACON_LEN) return
        val tag = ((data[0].toInt() and 0xff) shl 8) or (data[1].toInt() and 0xff)
        if (groupTag >= 0 && tag != groupTag) return
        var phy = 1
        var legacy = true
        if (Build.VERSION.SDK_INT >= 26) {
            phy = r.primaryPhy
            legacy = r.isLegacy
        }
        val addr = r.device.address
        main.post {
            emit(mapOf("t" to "beacon", "addr" to addr, "rssi" to r.rssi, "data" to data.copyOf(BEACON_LEN), "phy" to phy, "legacy" to legacy))
        }
    }

    // --------------------------------------------------------------------------------------------------- GATT server
    private fun openGattServer() {
        if (gattServer != null) return
        val m = manager ?: return
        val cb = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                val addr = device.address
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    val l = links.getOrPut(addr) { Link(addr) }
                    l.serverDevice = device
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    val l = links[addr] ?: return
                    l.serverDevice = null
                    l.serverSubscribed = false
                    if (l.gatt == null && l.l2cap == null) closeLink(l, notify = true)
                }
            }

            override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
                val l = links.getOrPut(device.address) { Link(device.address) }
                l.serverDevice = device
                l.serverSubscribed = value != null && value.isNotEmpty() && (value[0].toInt() and 0x01) != 0
                if (responseNeeded) try { gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null) } catch (_: Throwable) {}
                announce(l)
            }

            override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
                if (responseNeeded) try { gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null) } catch (_: Throwable) {}
                if (value == null || characteristic.uuid != DATA_UUID) return
                val l = links.getOrPut(device.address) { Link(device.address) }
                l.serverDevice = device
                onFragment(l, value)
            }

            override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
                links[device.address]?.let { it.mtu = maxOf(it.mtu, mtu) }
            }

            override fun onNotificationSent(device: BluetoothDevice, status: Int) {
                val l = links[device.address] ?: return
                synchronized(l) { l.gattBusy = false }
                pumpGatt(l)
            }
        }
        try {
            val server = m.openGattServer(context, cb) ?: return
            val ch = BluetoothGattCharacteristic(
                DATA_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            ch.addDescriptor(BluetoothGattDescriptor(CCCD_UUID, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
            val svc = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            svc.addCharacteristic(ch)
            server.addService(svc)
            gattServer = server
        } catch (e: Throwable) {
            emitError("gatt_server", e)
        }
    }

    private fun serverChar(): BluetoothGattCharacteristic? = gattServer?.getService(SERVICE_UUID)?.getCharacteristic(DATA_UUID)

    // ------------------------------------------------------------------------------------------------- GATT client
    /** Opens a link to a peer seen in a beacon (Dart decides who connects to whom). */
    fun connect(address: String, peerPsm: Int, coded: Boolean) {
        val a = adapter ?: return
        if (!running || !hasConnect() || links[address]?.gatt != null) return
        val device = try { a.getRemoteDevice(address) } catch (_: Throwable) { return }
        val l = links.getOrPut(address) { Link(address) }
        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    if (Build.VERSION.SDK_INT >= 26 && coded) {
                        try { gatt.setPreferredPhy(BluetoothDevice.PHY_LE_CODED_MASK, BluetoothDevice.PHY_LE_CODED_MASK, BluetoothDevice.PHY_OPTION_S8) } catch (_: Throwable) {}
                    }
                    if (!gatt.requestMtu(247)) gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    try { gatt.close() } catch (_: Throwable) {}
                    l.gatt = null
                    l.dataChar = null
                    if (l.serverDevice == null && l.l2cap == null) closeLink(l, notify = true)
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) l.mtu = mtu
                gatt.discoverServices()
            }

            override fun onPhyUpdate(gatt: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
                l.phy = txPhy
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val ch = gatt.getService(SERVICE_UUID)?.getCharacteristic(DATA_UUID)
                if (ch == null) {
                    try { gatt.disconnect() } catch (_: Throwable) {}
                    return
                }
                l.dataChar = ch
                gatt.setCharacteristicNotification(ch, true)
                val d = ch.getDescriptor(CCCD_UUID)
                if (d != null) writeDescriptor(gatt, d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                announce(l)
                main.removeCallbacks(rssiPoll)
                main.postDelayed(rssiPoll, RSSI_POLL_MS)
                if (Build.VERSION.SDK_INT >= 29 && peerPsm > 0) io.execute { openL2cap(device, l, peerPsm) }
            }

            // Android 12 and lower call this one; 13+ call the overload with the value (never both).
            @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                val v = characteristic.value ?: return
                onFragment(l, v)
            }

            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
                onFragment(l, value)
            }

            override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                synchronized(l) { l.gattBusy = false }
                pumpGatt(l)
            }

            override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) main.post { emit(mapOf("t" to "rssi", "addr" to address, "rssi" to rssi)) }
            }
        }
        try {
            l.gatt = if (Build.VERSION.SDK_INT >= 26) {
                val phy = if (coded) BluetoothDevice.PHY_LE_CODED_MASK or BluetoothDevice.PHY_LE_1M_MASK else BluetoothDevice.PHY_LE_1M_MASK
                device.connectGatt(context, false, cb, BluetoothDevice.TRANSPORT_LE, phy, main)
            } else {
                device.connectGatt(context, false, cb, BluetoothDevice.TRANSPORT_LE)
            }
        } catch (e: Throwable) {
            emitError("connect", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(gatt: BluetoothGatt, d: BluetoothGattDescriptor, value: ByteArray) {
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeDescriptor(d, value)
            } else {
                d.value = value
                gatt.writeDescriptor(d)
            }
        } catch (_: Throwable) {
        }
    }

    fun disconnect(address: String) {
        links[address]?.let { closeLink(it, notify = true) }
    }

    private val rssiPoll = object : Runnable {
        override fun run() {
            if (!running) return
            var any = false
            for (l in links.values) {
                val g = l.gatt ?: continue
                any = true
                try { g.readRemoteRssi() } catch (_: Throwable) {}
            }
            if (any) main.postDelayed(this, RSSI_POLL_MS)
        }
    }

    // ------------------------------------------------------------------------------------------------------ L2CAP
    private fun acceptLoop(server: BluetoothServerSocket) {
        while (running) {
            val s = try { server.accept() } catch (_: Throwable) { null } ?: break
            val addr = s.remoteDevice?.address ?: continue
            val l = links.getOrPut(addr) { Link(addr) }
            attachL2cap(l, s)
        }
    }

    private fun openL2cap(device: BluetoothDevice, l: Link, peerPsm: Int) {
        if (Build.VERSION.SDK_INT < 29 || l.l2cap != null) return
        try {
            val s = device.createInsecureL2capChannel(peerPsm)
            s.connect()
            attachL2cap(l, s)
        } catch (e: Throwable) {
            emitError("l2cap_connect", e) // the GATT link keeps carrying data
        }
    }

    private fun attachL2cap(l: Link, s: BluetoothSocket) {
        try {
            l.l2capOut = s.outputStream
            l.l2cap = s
            val input = s.inputStream
            announce(l, force = true)
            io.execute { readL2cap(l, s, input) }
        } catch (e: Throwable) {
            emitError("l2cap_attach", e)
        }
    }

    private fun readL2cap(l: Link, s: BluetoothSocket, input: InputStream) {
        val head = ByteArray(2)
        try {
            while (running) {
                if (!readFully(input, head)) break
                val n = ((head[0].toInt() and 0xff) shl 8) or (head[1].toInt() and 0xff)
                if (n <= 0 || n > MAX_FRAME) break
                val buf = ByteArray(n)
                if (!readFully(input, buf)) break
                main.post { emit(mapOf("t" to "frame", "addr" to l.address, "data" to buf, "via" to "l2cap")) }
            }
        } catch (_: Throwable) {
        }
        try { s.close() } catch (_: Throwable) {}
        if (l.l2cap === s) {
            l.l2cap = null
            l.l2capOut = null
            if (l.gatt == null && l.serverDevice == null) closeLink(l, notify = true) else announce(l, force = true)
        }
    }

    private fun readFully(input: InputStream, buf: ByteArray): Boolean {
        var o = 0
        while (o < buf.size) {
            val r = input.read(buf, o, buf.size - o)
            if (r < 0) return false
            o += r
        }
        return true
    }

    // ------------------------------------------------------------------------------------------------------- data
    /** Sends one frame on every ready link. Returns how many links took it. */
    fun send(frame: ByteArray): Int {
        if (!running || frame.isEmpty() || frame.size > MAX_FRAME) return 0
        var n = 0
        for (l in links.values) {
            val out = l.l2capOut
            if (out != null) {
                n++
                val copy = frame.copyOf()
                try {
                    l.writer.execute {
                        try {
                            val b = ByteArray(2 + copy.size)
                            b[0] = (copy.size shr 8).toByte()
                            b[1] = copy.size.toByte()
                            System.arraycopy(copy, 0, b, 2, copy.size)
                            out.write(b)
                            out.flush()
                        } catch (_: Throwable) {
                        }
                    }
                } catch (_: Throwable) {
                }
                continue
            }
            if ((l.gatt != null && l.dataChar != null) || (l.serverDevice != null && l.serverSubscribed)) {
                n++
                enqueueGatt(l, frame)
            }
        }
        return n
    }

    /** Fragments: one header byte (bit 7 first, bit 6 last, bits 0-5 frame counter) + up to MTU-4 bytes. */
    private fun enqueueGatt(l: Link, frame: ByteArray) {
        val chunk = maxOf(20, l.mtu - 4)
        synchronized(l) {
            if (l.gattQueue.size > 256) return // a stalled link never grows without bound (Dart re-sends what matters)
            val counter = l.txCounter and 0x3f
            l.txCounter++
            var o = 0
            while (o < frame.size) {
                val n = minOf(chunk, frame.size - o)
                val b = ByteArray(n + 1)
                var h = counter
                if (o == 0) h = h or 0x80
                if (o + n >= frame.size) h = h or 0x40
                b[0] = h.toByte()
                System.arraycopy(frame, o, b, 1, n)
                l.gattQueue.addLast(b)
                o += n
            }
        }
        pumpGatt(l)
    }

    @Suppress("DEPRECATION")
    private fun pumpGatt(l: Link) {
        val next: ByteArray = synchronized(l) {
            if (l.gattBusy || l.gattQueue.isEmpty()) {
                null
            } else {
                l.gattBusy = true
                l.gattQueue.removeFirst()
            }
        } ?: return
        var ok = false
        try {
            val g = l.gatt
            val ch = l.dataChar
            if (g != null && ch != null) {
                ok = if (Build.VERSION.SDK_INT >= 33) {
                    g.writeCharacteristic(ch, next, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothGatt.GATT_SUCCESS
                } else {
                    ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    ch.value = next
                    g.writeCharacteristic(ch)
                }
            } else {
                val dev = l.serverDevice
                val sc = serverChar()
                val server = gattServer
                if (dev != null && sc != null && server != null && l.serverSubscribed) {
                    ok = if (Build.VERSION.SDK_INT >= 33) {
                        server.notifyCharacteristicChanged(dev, sc, false, next) == BluetoothGatt.GATT_SUCCESS
                    } else {
                        sc.value = next
                        server.notifyCharacteristicChanged(dev, sc, false)
                    }
                }
            }
        } catch (_: Throwable) {
            ok = false
        }
        if (!ok) {
            synchronized(l) { l.gattBusy = false }
            // Busy stack: try again shortly (the callback that normally clears gattBusy will not come).
            main.postDelayed({ pumpGatt(l) }, 15)
        }
    }

    private fun onFragment(l: Link, v: ByteArray) {
        if (v.isEmpty()) return
        val h = v[0].toInt() and 0xff
        val counter = h and 0x3f
        var done: ByteArray? = null
        synchronized(l.rx) {
            if (h and 0x80 != 0) {
                l.rx.reset()
                l.rxCounter = counter
            }
            if (l.rxCounter != counter) {
                l.rx.reset()
                l.rxCounter = -1
                return
            }
            l.rx.write(v, 1, v.size - 1)
            if (l.rx.size() > MAX_FRAME) {
                l.rx.reset()
                l.rxCounter = -1
                return
            }
            if (h and 0x40 != 0) {
                done = l.rx.toByteArray()
                l.rx.reset()
                l.rxCounter = -1
            }
        }
        val frame = done ?: return
        main.post { emit(mapOf("t" to "frame", "addr" to l.address, "data" to frame, "via" to "gatt")) }
    }

    private fun announce(l: Link, force: Boolean = false) {
        if (!l.ready()) return
        if (l.announced && !force) return
        l.announced = true
        main.post { emit(mapOf("t" to "link", "addr" to l.address, "up" to true, "via" to l.via(), "phy" to l.phy)) }
    }

    private fun closeLink(l: Link, notify: Boolean) {
        links.remove(l.address)
        try { l.l2cap?.close() } catch (_: Throwable) {}
        l.l2cap = null
        l.l2capOut = null
        try { l.gatt?.disconnect() } catch (_: Throwable) {}
        try { l.gatt?.close() } catch (_: Throwable) {}
        l.gatt = null
        val dev = l.serverDevice
        if (dev != null) try { gattServer?.cancelConnection(dev) } catch (_: Throwable) {}
        l.serverDevice = null
        l.writer.shutdownNow()
        if (notify && l.announced) main.post { emit(mapOf("t" to "link", "addr" to l.address, "up" to false)) }
    }

    fun linkCount(): Int = links.values.count { it.ready() }

    private fun emitError(what: String, e: Throwable) {
        main.post { emit(mapOf("t" to "error", "what" to what, "message" to (e.message ?: e.javaClass.simpleName))) }
    }
}
