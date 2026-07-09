package com.example.travelsafetyapp.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Location
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import com.example.travelsafetyapp.MainActivity
import com.example.travelsafetyapp.R
import com.example.travelsafetyapp.data.RepositoryProvider
import com.example.travelsafetyapp.domain.model.DistanceAlert
import com.example.travelsafetyapp.domain.model.MemberLocation
import com.google.android.gms.location.*
import com.google.firebase.database.*
import java.util.UUID
import kotlinx.coroutines.*

class TrackingService : Service() {

    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private var locationCallback: LocationCallback? = null
    
    private var currentIntervalSeconds = 15L
    private var currentPriority = Priority.PRIORITY_HIGH_ACCURACY
    private var lastMovementTime = System.currentTimeMillis()
    private var isTracking = false

    // Firebase listeners for background notifications
    private var alertListener: ValueEventListener? = null
    private var messageListener: ValueEventListener? = null
    private var nextStopListener: ValueEventListener? = null
    private var waitListener: ValueEventListener? = null
    private var groupRef: DatabaseReference? = null
    private var currentUserId: String = ""
    private var knownAlertIds = mutableSetOf<String>()
    private var knownMessageIds = mutableSetOf<String>()
    private var lastKnownNextStop = ""
    private var knownWaitUserIds = mutableSetOf<String>()
    private var distanceAlertListener: ValueEventListener? = null
    private var knownDistanceAlertIds = mutableSetOf<String>()
    private val lastDistanceAlertTimes = mutableMapOf<String, Long>()
    private var notificationIdCounter = 300
    private val waitJobs = java.util.concurrent.ConcurrentHashMap<String, Job>()

    companion object {
        private const val TAG = "TrackingService"
        const val CHANNEL_ID = "travel_safety_tracking_channel"
        const val ALERT_CHANNEL_ID = "travel_safety_alert_channel"
        const val MESSAGE_CHANNEL_ID = "travel_safety_message_channel"
        const val NOTIFICATION_ID = 101

        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val ACTION_UPDATE_INTERVAL = "ACTION_UPDATE_INTERVAL"
        
        const val EXTRA_INTERVAL = "EXTRA_INTERVAL"
        const val EXTRA_GROUP_ID = "EXTRA_GROUP_ID"
        const val EXTRA_USER_ID = "EXTRA_USER_ID"
    }

    override fun onCreate() {
        super.onCreate()
        RepositoryProvider.initialize(applicationContext)
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        Log.d(TAG, "onStartCommand action: $action")
        
        when (action) {
            ACTION_START -> {
                val groupId = intent.getStringExtra(EXTRA_GROUP_ID)
                val userId = intent.getStringExtra(EXTRA_USER_ID) ?: ""
                currentUserId = userId
                
                val prefs = getSharedPreferences("coroute_prefs", Context.MODE_PRIVATE)
                val tripState = prefs.getString("trip_state", "NOT_STARTED") ?: "NOT_STARTED"
                if (tripState == "PAUSED") {
                    currentIntervalSeconds = 300L
                    currentPriority = Priority.PRIORITY_LOW_POWER
                } else {
                    currentIntervalSeconds = 15L
                    currentPriority = Priority.PRIORITY_HIGH_ACCURACY
                }

                if (!isTracking) {
                    startForeground(NOTIFICATION_ID, buildNotification())
                    startTracking()
                } else {
                    restartTracking()
                }
                if (groupId != null && !RepositoryProvider.isSimulationMode()) {
                    setupFirebaseListeners(groupId)
                }
            }
            ACTION_STOP -> {
                stopTracking()
                removeFirebaseListeners()
                stopSelf()
            }
            ACTION_UPDATE_INTERVAL -> {
                val newInterval = intent.getLongExtra(EXTRA_INTERVAL, 15L)
                val newPriority = intent.getIntExtra("EXTRA_PRIORITY", Priority.PRIORITY_HIGH_ACCURACY)
                if (newInterval != currentIntervalSeconds || newPriority != currentPriority) {
                    currentIntervalSeconds = newInterval
                    currentPriority = newPriority
                    if (isTracking) {
                        restartTracking()
                    }
                }
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startTracking() {
        isTracking = true
        requestLocationUpdates()
    }

    private fun restartTracking() {
        removeLocationUpdates()
        requestLocationUpdates()
    }

    private fun stopTracking() {
        isTracking = false
        removeLocationUpdates()
        serviceScope.cancel()
    }

    private fun requestLocationUpdates() {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
            ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "Location permissions not granted for tracking service")
            return
        }

        val locationRequest = LocationRequest.Builder(
            currentPriority, 
            currentIntervalSeconds * 1000L
        ).apply {
            setMinUpdateIntervalMillis((currentIntervalSeconds / 2) * 1000L)
            setWaitForAccurateLocation(false)
        }.build()

        locationCallback = object : LocationCallback() {
            override fun onLocationResult(locationResult: LocationResult) {
                locationResult.lastLocation?.let { location ->
                    onLocationChanged(location)
                }
            }
        }

        fusedLocationClient.requestLocationUpdates(
            locationRequest,
            locationCallback!!,
            Looper.getMainLooper()
        )
        Log.d(TAG, "Location updates requested with interval: $currentIntervalSeconds s")
    }

    private fun removeLocationUpdates() {
        locationCallback?.let {
            fusedLocationClient.removeLocationUpdates(it)
        }
        locationCallback = null
    }

    private fun onLocationChanged(location: Location) {
        val speedKmh = location.speed * 3.6f
        val batteryPct = getBatteryPercentage()
        
        if (speedKmh >= 1.0f) {
            lastMovementTime = System.currentTimeMillis()
        }
        val stationaryDurationSecs = (System.currentTimeMillis() - lastMovementTime) / 1000L
        
        val repo = RepositoryProvider.getGroupRepository()
        val currentLoc = repo.memberLocations.value[currentUserId]
        val prefs = getSharedPreferences("coroute_prefs", Context.MODE_PRIVATE)
        val tripState = prefs.getString("trip_state", "NOT_STARTED") ?: "NOT_STARTED"
        val isPaused = tripState == "PAUSED"

        val (targetInterval, targetPriority) = when {
            isPaused -> {
                // If paused: 5 minutes interval, low power!
                300L to Priority.PRIORITY_LOW_POWER
            }
            batteryPct < 20 -> {
                // If low battery (<20%): 60 seconds interval, balanced power accuracy!
                60L to Priority.PRIORITY_BALANCED_POWER_ACCURACY
            }
            speedKmh < 1.0f -> {
                // Idle: 20 seconds interval
                20L to Priority.PRIORITY_BALANCED_POWER_ACCURACY
            }
            else -> {
                // Moving: 5 seconds high accuracy
                5L to Priority.PRIORITY_HIGH_ACCURACY
            }
        }
        
        Log.d(TAG, "Location: lat=${location.latitude}, lng=${location.longitude}, speed=$speedKmh km/h, battery=$batteryPct%, tripState=$tripState, target=${targetInterval}s")

        if (targetInterval != currentIntervalSeconds || targetPriority != currentPriority) {
            serviceScope.launch {
                val intent = Intent(this@TrackingService, TrackingService::class.java).apply {
                    action = ACTION_UPDATE_INTERVAL
                    putExtra(EXTRA_INTERVAL, targetInterval)
                    putExtra("EXTRA_PRIORITY", targetPriority)
                }
                startService(intent)
            }
        }

        serviceScope.launch {
            if (tripState == "STARTED") {
                val memberLoc = MemberLocation(
                    lat = location.latitude,
                    lng = location.longitude,
                    speed = speedKmh,
                    battery = batteryPct,
                    lastUpdated = System.currentTimeMillis(),
                    isPaused = false,
                    tripState = tripState,
                    phoneNumber = prefs.getString("user_phone", "") ?: "",
                    isCoRiding = currentLoc?.isCoRiding ?: false,
                    ridingWithUserId = currentLoc?.ridingWithUserId ?: "",
                    ridingWithUserName = currentLoc?.ridingWithUserName ?: "",
                    vehicleType = currentLoc?.vehicleType ?: "",
                    vehicleNo = currentLoc?.vehicleNo ?: "",
                    vehicleColor = currentLoc?.vehicleColor ?: "",
                    emergencyContact = currentLoc?.emergencyContact ?: "",
                    ridingRole = currentLoc?.ridingRole ?: ""
                )
                repo.updateLocation(memberLoc)

                // Calculate distance alerts
                val allLocs = repo.memberLocations.value
                val leadLoc = allLocs.values.firstOrNull { it.ridingRole.uppercase() == "LEAD" }
                val refPoint: Pair<Double, Double>? = when {
                    leadLoc != null && leadLoc.lat != 0.0 && leadLoc.lng != 0.0 -> {
                        leadLoc.lat to leadLoc.lng
                    }
                    allLocs.size > 1 -> {
                        val otherLocs = allLocs.filter { it.key != currentUserId && it.value.lat != 0.0 && it.value.lng != 0.0 }
                        if (otherLocs.isNotEmpty()) {
                            val avgLat = otherLocs.map { it.value.lat }.average()
                            val avgLng = otherLocs.map { it.value.lng }.average()
                            avgLat to avgLng
                        } else null
                    }
                    else -> null
                }

                if (refPoint != null && location.latitude != 0.0 && location.longitude != 0.0) {
                    val distance = calculateHaversineDistanceKm(location.latitude, location.longitude, refPoint.first, refPoint.second)
                    val alertLevel = when {
                        distance > 2.0 -> "CRITICAL"
                        distance > 1.0 -> "WARNING"
                        else -> null
                    }

                    if (alertLevel != null) {
                        val key = "${currentUserId}_${alertLevel}"
                        val lastTime = lastDistanceAlertTimes[key] ?: 0L
                        val now = System.currentTimeMillis()
                        
                        if (now - lastTime > 120_000L) {
                            lastDistanceAlertTimes[key] = now
                            val alertId = UUID.randomUUID().toString()
                            val alert = DistanceAlert(
                                alertId = alertId,
                                userId = currentUserId,
                                userName = currentLoc?.userName ?: prefs.getString("saved_user_display_name", "You") ?: "Rider",
                                distance = distance,
                                level = alertLevel,
                                timestamp = now,
                                resolved = false
                            )
                            repo.triggerDistanceAlert(alert)
                        }
                    } else {
                        // Catching up: Resolve any active alerts for this user
                        val activeAlerts = repo.activeDistanceAlerts.value
                        activeAlerts.forEach { alert ->
                            if (alert.userId == currentUserId && !alert.resolved) {
                                repo.resolveDistanceAlert(alert.alertId)
                            }
                        }
                    }
                }

                // Check Lead Behind Alert
                if (leadLoc != null && leadLoc.lat != 0.0 && leadLoc.lng != 0.0) {
                    val nextStopLat = repo.activeGroup.value?.nextStopLat ?: 0.0
                    val nextStopLng = repo.activeGroup.value?.nextStopLng ?: 0.0
                    if (nextStopLat != 0.0 && nextStopLng != 0.0) {
                        val leadDist = calculateHaversineDistanceKm(leadLoc.lat, leadLoc.lng, nextStopLat, nextStopLng)
                        val middleLocs = allLocs.values.filter { it.ridingRole.uppercase() == "MIDDLE" && it.lat != 0.0 && it.lng != 0.0 }
                        var isLeadBehind = false
                        for (mid in middleLocs) {
                            val midDist = calculateHaversineDistanceKm(mid.lat, mid.lng, nextStopLat, nextStopLng)
                            if (leadDist > midDist) {
                                isLeadBehind = true
                                break
                            }
                        }
                        if (isLeadBehind) {
                            val key = "lead_behind_group"
                            val lastTime = lastDistanceAlertTimes[key] ?: 0L
                            val now = System.currentTimeMillis()
                            if (now - lastTime > 120_000L) {
                                lastDistanceAlertTimes[key] = now
                                val alert = DistanceAlert(
                                    alertId = "lead_behind_alert",
                                    userId = leadLoc.userName,
                                    userName = "Lead Rider",
                                    distance = 0.0,
                                    level = "LEAD_BEHIND",
                                    timestamp = now,
                                    resolved = false
                                )
                                repo.triggerDistanceAlert(alert)
                            }
                        } else {
                            val activeAlerts = repo.activeDistanceAlerts.value
                            if (activeAlerts.any { it.alertId == "lead_behind_alert" && !it.resolved }) {
                                repo.resolveDistanceAlert("lead_behind_alert")
                            }
                        }
                    }
                }

                // Check Sweep Out of Position Alert (not last)
                val sweepLoc = allLocs.values.firstOrNull { it.ridingRole.uppercase() == "SWEEP" }
                if (leadLoc != null && sweepLoc != null && leadLoc.lat != 0.0 && leadLoc.lng != 0.0 && sweepLoc.lat != 0.0 && sweepLoc.lng != 0.0) {
                    val sweepDist = calculateHaversineDistanceKm(sweepLoc.lat, sweepLoc.lng, leadLoc.lat, leadLoc.lng)
                    val middleLocs = allLocs.values.filter { it.ridingRole.uppercase() == "MIDDLE" && it.lat != 0.0 && it.lng != 0.0 }
                    var isSweepNotLast = false
                    for (mid in middleLocs) {
                        val midDist = calculateHaversineDistanceKm(mid.lat, mid.lng, leadLoc.lat, leadLoc.lng)
                        if (midDist > sweepDist) {
                            isSweepNotLast = true
                            break
                        }
                    }
                    if (isSweepNotLast) {
                        val key = "sweep_not_last"
                        val lastTime = lastDistanceAlertTimes[key] ?: 0L
                        val now = System.currentTimeMillis()
                        if (now - lastTime > 120_000L) {
                            lastDistanceAlertTimes[key] = now
                            val alert = DistanceAlert(
                                alertId = "sweep_not_last_alert",
                                userId = sweepLoc.userName,
                                userName = "Sweep Rider",
                                distance = 0.0,
                                level = "SWEEP_NOT_LAST",
                                timestamp = now,
                                resolved = false
                            )
                            repo.triggerDistanceAlert(alert)
                        }
                    } else {
                        val activeAlerts = repo.activeDistanceAlerts.value
                        if (activeAlerts.any { it.alertId == "sweep_not_last_alert" && !it.resolved }) {
                            repo.resolveDistanceAlert("sweep_not_last_alert")
                        }
                    }
                }
            }
        }

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, buildNotification(speedKmh, batteryPct))
    }

    private fun setupFirebaseListeners(groupId: String) {
        removeFirebaseListeners()
        try {
            val database = FirebaseDatabase.getInstance("https://smart-kirana-shop-5bb2b-default-rtdb.asia-southeast1.firebasedatabase.app")
            val ref = database.getReference("groups").child(groupId)
            groupRef = ref

            val listenerStartTime = System.currentTimeMillis()

            alertListener = ref.child("alerts").addValueEventListener(object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    for (child in snapshot.children) {
                        val alertId = child.child("alertId").getValue(String::class.java) ?: continue
                        val timestamp = child.child("timestamp").getValue(Long::class.java) ?: 0L
                        if (timestamp < listenerStartTime) continue

                        val resolved = child.child("resolved").getValue(Boolean::class.java) ?: false
                        val senderId = child.child("userId").getValue(String::class.java) ?: ""
                        val senderName = child.child("userName").getValue(String::class.java) ?: "Someone"
                        val lat = child.child("latitude").getValue(Double::class.java) ?: 0.0
                        val lng = child.child("longitude").getValue(Double::class.java) ?: 0.0
                        val type = child.child("type").getValue(String::class.java) ?: "SOS"
                        val targetUserId = child.child("targetUserId").getValue(String::class.java) ?: ""
                        
                        if (!resolved && senderId != currentUserId && !knownAlertIds.contains(alertId)) {
                            knownAlertIds.add(alertId)
                            if (type == "INDIVIDUAL_SOS") {
                                val targetName = if (targetUserId == currentUserId) "You" else {
                                    val locs = RepositoryProvider.getGroupRepository().memberLocations.value
                                    locs[targetUserId]?.userName ?: "Someone"
                                }
                                postHighPriorityNotification(
                                    "🚨 SOS ALERT",
                                    "SOS triggered for $targetName",
                                    lat, lng, isAlarm = true
                                )
                            } else {
                                postHighPriorityNotification(
                                    "🚨 SOS ALERT: $senderName",
                                    "$senderName needs immediate help! Tap to open their location.",
                                    lat, lng, isAlarm = true
                                )
                            }
                        }
                    }
                }
                override fun onCancelled(error: DatabaseError) {}
            })

            messageListener = ref.child("messages").addValueEventListener(object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    for (child in snapshot.children) {
                        val msgId = child.child("messageId").getValue(String::class.java) ?: continue
                        val timestamp = child.child("timestamp").getValue(Long::class.java) ?: 0L
                        if (timestamp < listenerStartTime) continue

                        val senderId = child.child("senderId").getValue(String::class.java) ?: ""
                        val senderName = child.child("senderName").getValue(String::class.java) ?: "Someone"
                        val content = child.child("content").getValue(String::class.java) ?: ""
                        val priority = child.child("priority").getValue(String::class.java) ?: "Medium"
                        
                        if (senderId != currentUserId && !knownMessageIds.contains(msgId)) {
                            knownMessageIds.add(msgId)
                            val isAlarm = priority == "High"
                            val title = when (priority) {
                                "High" -> "🔔 URGENT from $senderName"
                                "Medium" -> "📢 Message from $senderName"
                                else -> "💬 $senderName says"
                            }
                            postHighPriorityNotification(title, content, 0.0, 0.0, isAlarm = isAlarm)
                        }
                    }
                }
                override fun onCancelled(error: DatabaseError) {}
            })

            nextStopListener = ref.child("nextStopPoint").addValueEventListener(object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    val nextStop = snapshot.getValue(String::class.java) ?: ""
                    if (nextStop.isNotBlank() && nextStop != lastKnownNextStop && lastKnownNextStop.isNotEmpty()) {
                        postHighPriorityNotification(
                            "📍 Next Stop Updated",
                            "New destination: $nextStop",
                            0.0, 0.0, isAlarm = false
                        )
                    }
                    lastKnownNextStop = nextStop
                }
                override fun onCancelled(error: DatabaseError) {}
            })

            waitListener = ref.child("waitRequests").addValueEventListener(object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    val activeUserIds = mutableSetOf<String>()
                    
                    // Process active wait requests
                    for (child in snapshot.children) {
                        val userId = child.key ?: continue
                        val timestamp = child.child("timestamp").getValue(Long::class.java) ?: 0L
                        if (timestamp < listenerStartTime) continue

                        activeUserIds.add(userId)
                        val userName = child.child("userName").getValue(String::class.java) ?: "Someone"
                        val waitMins = child.child("waitMinutes").getValue(Int::class.java) ?: 0
                        
                        if (!knownWaitUserIds.contains(userId)) {
                            knownWaitUserIds.add(userId)
                            // 1. Post immediate warning notification: stop in 2 minutes
                            postHighPriorityNotification(
                                "⚠️ Pull Over: Wait Requested",
                                "$userName requested a wait! Stopping group in 2 minutes.",
                                0.0, 0.0, isAlarm = false
                            )
                            
                            // 2. Start a 2-minute background countdown alarm job
                            val job = serviceScope.launch {
                                delay(120000L) // Wait exactly 2 minutes
                                postHighPriorityNotification(
                                    "🚨 STOP: Wait Time Active",
                                    "2-minute buffer over! Sounding stop alarm for $userName's wait request.",
                                    0.0, 0.0, isAlarm = true
                                )
                            }
                            waitJobs[userId] = job
                        }
                    }

                    // Handle resolved wait requests (removed from Firebase database)
                    val resolvedUserIds = knownWaitUserIds - activeUserIds
                    resolvedUserIds.forEach { userId ->
                        waitJobs[userId]?.cancel()
                        waitJobs.remove(userId)
                        knownWaitUserIds.remove(userId)
                        postHighPriorityNotification(
                            "✅ Wait Resolved",
                            "Wait request has been resolved. You can resume riding.",
                            0.0, 0.0, isAlarm = false
                        )
                    }
                }
                override fun onCancelled(error: DatabaseError) {}
            })

            distanceAlertListener = ref.child("distanceAlerts").addValueEventListener(object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    for (child in snapshot.children) {
                        val alertId = child.child("alertId").getValue(String::class.java) ?: continue
                        val resolved = child.child("resolved").getValue(Boolean::class.java) ?: false
                        val senderId = child.child("userId").getValue(String::class.java) ?: ""
                        val senderName = child.child("userName").getValue(String::class.java) ?: "Someone"
                        val distance = child.child("distance").getValue(Double::class.java) ?: 0.0
                        val level = child.child("level").getValue(String::class.java) ?: "WARNING"
                        
                        if (!resolved && senderId != currentUserId && !knownDistanceAlertIds.contains(alertId)) {
                            knownDistanceAlertIds.add(alertId)
                            val isCritical = level == "CRITICAL"
                            val title = when (level) {
                                "LEAD_BEHIND" -> "🚨 Lead Rider Behind"
                                "SWEEP_NOT_LAST" -> "⚠️ Sweep Not Last"
                                "CRITICAL" -> "🚨 CRITICAL: Rider Falling Behind"
                                else -> "⚠️ Warning: Rider Falling Behind"
                            }
                            val body = when (level) {
                                "LEAD_BEHIND" -> "Lead rider is behind the group"
                                "SWEEP_NOT_LAST" -> "Sweep rider is out of position (not last)"
                                else -> {
                                    val distText = String.format("%.1f", distance)
                                    "$senderName is falling behind by $distText km!"
                                }
                            }
                            postHighPriorityNotification(title, body, 0.0, 0.0, isAlarm = isCritical || level == "LEAD_BEHIND")
                        }
                    }
                }
                override fun onCancelled(error: DatabaseError) {}
            })

            Log.d(TAG, "Firebase background listeners registered for group: $groupId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to setup Firebase listeners: ${e.message}")
        }
    }

    private fun removeFirebaseListeners() {
        groupRef?.let { ref ->
            alertListener?.let { ref.child("alerts").removeEventListener(it) }
            messageListener?.let { ref.child("messages").removeEventListener(it) }
            nextStopListener?.let { ref.child("nextStopPoint").removeEventListener(it) }
            waitListener?.let { ref.child("waitRequests").removeEventListener(it) }
            distanceAlertListener?.let { ref.child("distanceAlerts").removeEventListener(it) }
        }
        waitJobs.values.forEach { it.cancel() }
        waitJobs.clear()
        alertListener = null
        messageListener = null
        nextStopListener = null
        waitListener = null
        distanceAlertListener = null
        groupRef = null
    }

    private fun postHighPriorityNotification(title: String, body: String, lat: Double, lng: Double, isAlarm: Boolean) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = if (isAlarm) ALERT_CHANNEL_ID else MESSAGE_CHANNEL_ID
        val nId = notificationIdCounter++

        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, nId, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setPriority(if (isAlarm) NotificationCompat.PRIORITY_MAX else NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setCategory(if (isAlarm) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        if (isAlarm) {
            val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            builder.setSound(alarmUri)
            builder.setVibrate(longArrayOf(0, 500, 200, 500, 200, 500))
        } else {
            val defaultSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            builder.setSound(defaultSound)
        }

        if (lat != 0.0 && lng != 0.0) {
            val mapsIntent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("google.navigation:q=$lat,$lng"))
            mapsIntent.setPackage("com.google.android.apps.maps")
            val mapsPendingIntent = PendingIntent.getActivity(
                this, nId + 1000, mapsIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.addAction(android.R.drawable.ic_menu_mapmode, "Open in Maps", mapsPendingIntent)
        }

        notificationManager.notify(nId, builder.build())
    }

    private fun getBatteryPercentage(): Int {
        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val batteryStatus = registerReceiver(null, filter)
        val level = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        return if (level >= 0 && scale > 0) {
            (level * 100 / scale)
        } else {
            100
        }
    }

    private fun buildNotification(speedKmh: Float = 0f, batteryPct: Int = 100): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openAppPendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, TrackingService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val prefs = getSharedPreferences("coroute_prefs", android.content.Context.MODE_PRIVATE)
        val tripState = prefs.getString("trip_state", "NOT_STARTED") ?: "NOT_STARTED"

        val speedText = String.format("%.1f", speedKmh)
        val isSimulated = RepositoryProvider.isSimulationMode()
        val modeTag = if (isSimulated) "[SIMULATION] " else ""
        
        val contentText = when (tripState) {
            "STARTED" -> "Sharing live location. Speed: $speedText km/h | Battery: $batteryPct%"
            "PAUSED" -> "Trip Paused. Location sharing is inactive. Battery: $batteryPct%"
            else -> "Trip Inactive. Battery: $batteryPct%"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("${modeTag}Group Live Tracking ($tripState)")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openAppPendingIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop Tracking",
                stopPendingIntent
            )
            .build()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            
            val trackingChannel = NotificationChannel(CHANNEL_ID, "Travel Group Location Tracking", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Displays status of travel group location tracking"
            }
            notificationManager.createNotificationChannel(trackingChannel)

            val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val alertChannel = NotificationChannel(ALERT_CHANNEL_ID, "Safety Alerts & SOS", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Urgent safety alerts and SOS notifications"
                setSound(alarmUri, AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 200, 500, 200, 500)
                setBypassDnd(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            notificationManager.createNotificationChannel(alertChannel)

            val messageChannel = NotificationChannel(MESSAGE_CHANNEL_ID, "Group Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Priority group messages from trip members"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            notificationManager.createNotificationChannel(messageChannel)
        }
    }

    private fun calculateHaversineDistanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6371.0 // Earth radius in km
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) *
                Math.sin(dLon / 2) * Math.sin(dLon / 2)
        val c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
        return r * c
    }

    override fun onDestroy() {
        removeFirebaseListeners()
        stopTracking()
        super.onDestroy()
    }
}
