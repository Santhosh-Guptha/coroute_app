package com.example.travelsafetyapp.data.repository

import com.example.travelsafetyapp.domain.model.Group
import com.example.travelsafetyapp.domain.model.MemberLocation
import com.example.travelsafetyapp.domain.model.DistanceAlert
import com.example.travelsafetyapp.domain.model.GroupMessage
import com.example.travelsafetyapp.domain.model.SOSAlert
import com.example.travelsafetyapp.domain.model.WaitRequest
import com.example.travelsafetyapp.domain.model.LatLngPoint
import com.example.travelsafetyapp.domain.repository.GroupRepository
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.DatabaseReference
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.util.UUID

class FirebaseGroupRepository(private val context: android.content.Context) : GroupRepository {
    private val database: FirebaseDatabase by lazy { 
        val db = FirebaseDatabase.getInstance("https://smart-kirana-shop-5bb2b-default-rtdb.asia-southeast1.firebasedatabase.app") 
        try {
            db.setPersistenceEnabled(true)
        } catch (_: Exception) {}
        db
    }
    private var groupRef: DatabaseReference? = null
    private var locationListener: ValueEventListener? = null
    private var alertListener: ValueEventListener? = null
    private var messageListener: ValueEventListener? = null
    private var distanceAlertListener: ValueEventListener? = null
    private var groupListener: ValueEventListener? = null
    private val repositoryScope = CoroutineScope(Dispatchers.IO)
    private var sessionJoinTime: Long = 0L
    
    private val _activeGroup = MutableStateFlow<Group?>(null)
    override val activeGroup: StateFlow<Group?> = _activeGroup.asStateFlow()

    private val _memberLocations = MutableStateFlow<Map<String, MemberLocation>>(emptyMap())
    override val memberLocations: StateFlow<Map<String, MemberLocation>> = _memberLocations.asStateFlow()

    private val _activeSOSAlerts = MutableStateFlow<List<SOSAlert>>(emptyList())
    override val activeSOSAlerts: StateFlow<List<SOSAlert>> = _activeSOSAlerts.asStateFlow()

    private val _activeMessages = MutableStateFlow<List<GroupMessage>>(emptyList())
    override val activeMessages: StateFlow<List<GroupMessage>> = _activeMessages.asStateFlow()

    private val _activeDistanceAlerts = MutableStateFlow<List<DistanceAlert>>(emptyList())
    override val activeDistanceAlerts: StateFlow<List<DistanceAlert>> = _activeDistanceAlerts.asStateFlow()

    override val currentUserId: String = getOrGeneratePersistentUserId(context)
    private var currentUserName: String = "User"

    private fun getOrGeneratePersistentUserId(ctx: android.content.Context): String {
        val prefs = ctx.getSharedPreferences("coroute_prefs", android.content.Context.MODE_PRIVATE)
        var uid = prefs.getString("persistent_user_id", null)
        if (uid == null) {
            uid = UUID.randomUUID().toString().take(12)
            prefs.edit().putString("persistent_user_id", uid).apply()
        }
        return uid
    }

    override suspend fun createGroup(
        groupName: String,
        creatorName: String,
        startPoint: String,
        destination: String,
        nextStopPoint: String
    ): Result<String> {
        return try {
            var newGroupId = ""
            var pinIsUnique = false
            
            // Loop until a database-wide unique 6-digit pin is generated
            while (!pinIsUnique) {
                val candidatePin = (100000..999999).random().toString()
                val snapshot = database.getReference("groups").child(candidatePin).get().await()
                if (!snapshot.exists()) {
                    newGroupId = candidatePin
                    pinIsUnique = true
                }
            }
            
            currentUserName = creatorName
            
            val group = Group(
                groupId = newGroupId,
                name = groupName,
                createdBy = currentUserId,
                startPoint = startPoint,
                destination = destination,
                nextStopPoint = nextStopPoint,
                members = mapOf(currentUserId to true)
            )
            
            database.getReference("groups").child(newGroupId).setValue(group).await()
            uploadSavedVehicleProfile(newGroupId)
            listenToGroup(newGroupId)
            Result.success(newGroupId)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun joinGroup(groupId: String, memberName: String): Result<Boolean> {
        return try {
            currentUserName = memberName
            val groupSnapshot = database.getReference("groups").child(groupId).get().await()
            if (!groupSnapshot.exists()) {
                return Result.failure(Exception("Group not found"))
            }
            
            // Check if user is the group creator (auto-approve)
            val createdBy = groupSnapshot.child("createdBy").getValue(String::class.java) ?: ""
            if (createdBy == currentUserId) {
                // Creator rejoining - add directly to members
                database.getReference("groups").child(groupId)
                    .child("members").child(currentUserId).setValue(true).await()
                uploadSavedVehicleProfile(groupId)
            } else {
                // Add to pendingMembers for admin approval
                database.getReference("groups").child(groupId)
                    .child("pendingMembers").child(currentUserId).setValue(memberName).await()
            }
            
            listenToGroup(groupId)
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun leaveGroup(): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.success(true)
            
            stopListening()
            
            // Remove from members and locations
            database.getReference("groups").child(groupId)
                .child("members").child(currentUserId).removeValue().await()
            database.getReference("groups").child(groupId)
                .child("locations").child(currentUserId).removeValue().await()
                
            _activeGroup.value = null
            _memberLocations.value = emptyMap()
            _activeSOSAlerts.value = emptyList()
            _activeMessages.value = emptyList()
            _activeDistanceAlerts.value = emptyList()
            
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun updateLocation(location: MemberLocation): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.success(true)
            val ref = database.getReference("groups").child(groupId)
                .child("locations").child(currentUserId)
            
            val prefs = context.getSharedPreferences("coroute_prefs", android.content.Context.MODE_PRIVATE)
            val currentTripState = prefs.getString("trip_state", "NOT_STARTED") ?: "NOT_STARTED"
            val userPhone = prefs.getString("user_phone", "") ?: ""
            
            val updates = mapOf(
                "lat" to location.lat,
                "lng" to location.lng,
                "speed" to location.speed,
                "battery" to location.battery,
                "lastUpdated" to location.lastUpdated,
                "userName" to currentUserName,
                "isPaused" to location.isPaused,
                "isCoRiding" to location.isCoRiding,
                "ridingWithUserId" to location.ridingWithUserId,
                "ridingWithUserName" to location.ridingWithUserName,
                "vehicleType" to location.vehicleType,
                "vehicleNo" to location.vehicleNo,
                "vehicleColor" to location.vehicleColor,
                "emergencyContact" to location.emergencyContact,
                "ridingRole" to location.ridingRole,
                "tripState" to currentTripState,
                "phoneNumber" to userPhone
            )
            ref.updateChildren(updates).await()

            // Update groups/{groupId}/members/{userId}
            val memberRef = database.getReference("groups").child(groupId)
                .child("members").child(currentUserId)
            val memberUpdates = mapOf(
                "tripState" to currentTripState,
                "vehicleNumber" to location.vehicleNo,
                "lastUpdated" to location.lastUpdated
            )
            memberRef.updateChildren(memberUpdates).await()

            // Update locations/{userId}
            val globalLocRef = database.getReference("locations").child(currentUserId)
            val globalLocUpdates = mapOf(
                "lat" to location.lat,
                "lng" to location.lng,
                "speed" to location.speed,
                "tripState" to currentTripState
            )
            globalLocRef.updateChildren(globalLocUpdates).await()

            // Save to route history trace if position changed and NOT paused and trip is STARTED
            if (!location.isPaused && currentTripState == "STARTED") {
                val currentMemberLoc = _memberLocations.value[currentUserId]
                val lastPoint = currentMemberLoc?.routeHistory?.values?.lastOrNull()
                if (lastPoint == null || lastPoint.lat != location.lat || lastPoint.lng != location.lng) {
                    val point = LatLngPoint(location.lat, location.lng)
                    ref.child("routeHistory").push().setValue(point).await()
                }
            }
            
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun triggerSOS(latitude: Double, longitude: Double, targetUserId: String, type: String, triggeredBy: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            val alertId = UUID.randomUUID().toString()
            val alert = SOSAlert(
                alertId = alertId,
                userId = currentUserId,
                userName = currentUserName,
                timestamp = System.currentTimeMillis(),
                latitude = latitude,
                longitude = longitude,
                targetUserId = targetUserId,
                type = type,
                triggeredBy = triggeredBy.ifBlank { currentUserId }
            )
            database.getReference("groups").child(groupId)
                .child("alerts").child(alertId).setValue(alert).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun resolveSOS(alertId: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            database.getReference("groups").child(groupId)
                .child("alerts").child(alertId).child("resolved").setValue(true).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun updateVehicleProfile(
        vehicleType: String,
        vehicleNo: String,
        vehicleColor: String,
        phoneNumber: String,
        emergencyContact: String,
        isCoRiding: Boolean,
        ridingWithUserId: String,
        ridingWithUserName: String,
        vehicleModel: String,
        emergencyContactName: String
    ): Result<Boolean> {
        return try {
            // 1. Write to users/{userId}/profile
            val profileRef = database.getReference("users").child(currentUserId).child("profile")
            val profileData = mapOf(
                "userName" to currentUserName,
                "vehicleType" to vehicleType,
                "vehicleNo" to vehicleNo,
                "vehicleColor" to vehicleColor,
                "phoneNumber" to phoneNumber,
                "emergencyContact" to emergencyContact,
                "isCoRiding" to isCoRiding,
                "ridingWithUserId" to ridingWithUserId,
                "ridingWithUserName" to ridingWithUserName,
                "vehicleModel" to vehicleModel,
                "emergencyContactName" to emergencyContactName
            )
            profileRef.setValue(profileData).await()

            // 2. Write to groups/{groupId}/locations/{userId} if active group exists
            val groupId = _activeGroup.value?.groupId
            if (groupId != null) {
                val ref = database.getReference("groups").child(groupId).child("locations").child(currentUserId)
                val snapshot = ref.get().await()
                val currentLoc = snapshot.getValue(MemberLocation::class.java) ?: MemberLocation(userName = currentUserName)
                val updatedLoc = currentLoc.copy(
                    vehicleType = vehicleType,
                    vehicleNo = vehicleNo,
                    vehicleColor = vehicleColor,
                    phoneNumber = phoneNumber,
                    emergencyContact = emergencyContact,
                    isCoRiding = isCoRiding,
                    ridingWithUserId = ridingWithUserId,
                    ridingWithUserName = ridingWithUserName,
                    vehicleModel = vehicleModel,
                    emergencyContactName = emergencyContactName
                )
                ref.setValue(updatedLoc).await()

                // 3. Write to groups/{groupId}/members/{userId}
                val memberRef = database.getReference("groups").child(groupId).child("members").child(currentUserId)
                val prefs = context.getSharedPreferences("coroute_prefs", android.content.Context.MODE_PRIVATE)
                val currentTripState = prefs.getString("trip_state", "NOT_STARTED") ?: "NOT_STARTED"
                val memberUpdates = mapOf(
                    "tripState" to currentTripState,
                    "vehicleNumber" to vehicleNo,
                    "lastUpdated" to System.currentTimeMillis()
                )
                memberRef.updateChildren(memberUpdates).await()
            }
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun updateNextStop(nextStopPoint: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            database.getReference("groups").child(groupId).child("nextStopPoint").setValue(nextStopPoint).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun addStopPoint(stopName: String): Result<Boolean> {
        return try {
            val group = _activeGroup.value ?: return Result.failure(Exception("No active group"))
            val updatedStops = group.stopPoints.toMutableList().apply { add(stopName) }
            database.getReference("groups").child(group.groupId).child("stopPoints").setValue(updatedStops).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun removeStopPoint(index: Int): Result<Boolean> {
        return try {
            val group = _activeGroup.value ?: return Result.failure(Exception("No active group"))
            val updatedStops = group.stopPoints.toMutableList()
            if (index in updatedStops.indices) {
                updatedStops.removeAt(index)
                database.getReference("groups").child(group.groupId).child("stopPoints").setValue(updatedStops).await()
                Result.success(true)
            } else {
                Result.failure(IndexOutOfBoundsException("Index $index out of bounds"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun requestWait(waitMinutes: Int): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            val request = WaitRequest(
                userId = currentUserId,
                userName = currentUserName,
                waitMinutes = waitMinutes,
                timestamp = System.currentTimeMillis()
            )
            database.getReference("groups").child(groupId).child("waitRequests").child(currentUserId).setValue(request).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun resolveWaitRequest(userId: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            database.getReference("groups").child(groupId).child("waitRequests").child(userId).removeValue().await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun assignRidingRole(userId: String, role: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            val targetRole = role.uppercase() // Normalize to LEAD, MIDDLE, SWEEP
            
            // Enforce only one LEAD and only one SWEEP
            if (targetRole == "LEAD" || targetRole == "SWEEP") {
                _memberLocations.value.forEach { (otherUid, loc) ->
                    val otherRole = loc.ridingRole.uppercase()
                    if (otherUid != userId && otherRole == targetRole) {
                        // Demote existing holder to MIDDLE
                        database.getReference("groups").child(groupId)
                            .child("members").child(otherUid).child("role").setValue("MIDDLE")
                        database.getReference("groups").child(groupId)
                            .child("locations").child(otherUid).child("ridingRole").setValue("MIDDLE")
                    }
                }
            }
            
            // Assign role to target member
            database.getReference("groups").child(groupId)
                .child("members").child(userId).child("role").setValue(targetRole).await()
            database.getReference("groups").child(groupId)
                .child("locations").child(userId).child("ridingRole").setValue(targetRole).await()
                
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun triggerDistanceAlert(alert: DistanceAlert): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            database.getReference("groups").child(groupId)
                .child("distanceAlerts").child(alert.alertId).setValue(alert).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun resolveDistanceAlert(alertId: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            database.getReference("groups").child(groupId)
                .child("distanceAlerts").child(alertId).child("resolved").setValue(true).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun sendGroupMessage(content: String, priority: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            val messageId = UUID.randomUUID().toString()
            val message = GroupMessage(
                messageId = messageId,
                senderId = currentUserId,
                senderName = currentUserName,
                content = content,
                priority = priority,
                timestamp = System.currentTimeMillis()
            )
            database.getReference("groups").child(groupId)
                .child("messages").child(messageId).setValue(message).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun updateGroupTripState(state: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            database.getReference("groups").child(groupId)
                .child("groupTripState").setValue(state).await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun approveMember(userId: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            val ref = database.getReference("groups").child(groupId)
            // Fetch name from pendingMembers first
            val pendingNameSnapshot = ref.child("pendingMembers").child(userId).get().await()
            val memberName = pendingNameSnapshot.getValue(String::class.java) ?: "User"

            // Move from pendingMembers to members
            ref.child("pendingMembers").child(userId).removeValue().await()
            ref.child("members").child(userId).setValue(true).await()

            // Write initial placeholder location
            ref.child("locations").child(userId).setValue(
                MemberLocation(
                    userName = memberName,
                    tripState = "NOT_STARTED",
                    lastUpdated = System.currentTimeMillis()
                )
            ).await()

            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun rejectMember(userId: String): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.failure(Exception("No active group"))
            database.getReference("groups").child(groupId)
                .child("pendingMembers").child(userId).removeValue().await()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun endTrip(): Result<Boolean> {
        return try {
            val groupId = _activeGroup.value?.groupId ?: return Result.success(true)
            stopListening()
            database.getReference("groups").child(groupId).removeValue().await()
            _activeGroup.value = null
            _memberLocations.value = emptyMap()
            _activeSOSAlerts.value = emptyList()
            _activeMessages.value = emptyList()
            _activeDistanceAlerts.value = emptyList()
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun listenToGroup(groupId: String) {
        stopListening()
        sessionJoinTime = System.currentTimeMillis()
        
        val ref = database.getReference("groups").child(groupId)
        groupRef = ref
        
        // Listen to locations
        locationListener = ref.child("locations").addValueEventListener(object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val locs = mutableMapOf<String, MemberLocation>()
                for (child in snapshot.children) {
                    val key = child.key ?: continue
                    val loc = child.getValue(MemberLocation::class.java) ?: continue
                    locs[key] = loc
                }
                _memberLocations.value = locs
            }

            override fun onCancelled(error: DatabaseError) {}
        })

        // Listen to alerts
        alertListener = ref.child("alerts").addValueEventListener(object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val alertsList = mutableListOf<SOSAlert>()
                for (child in snapshot.children) {
                    val alert = child.getValue(SOSAlert::class.java) ?: continue
                    if (!alert.resolved) {
                        alertsList.add(alert)
                    }
                }
                _activeSOSAlerts.value = alertsList
            }

            override fun onCancelled(error: DatabaseError) {}
        })

        // Listen to messages (only show live messages)
        messageListener = ref.child("messages").addValueEventListener(object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val msgList = mutableListOf<GroupMessage>()
                for (child in snapshot.children) {
                    val msg = child.getValue(GroupMessage::class.java) ?: continue
                    if (msg.timestamp >= sessionJoinTime) {
                        msgList.add(msg)
                    }
                }
                _activeMessages.value = msgList.sortedBy { it.timestamp }
            }

            override fun onCancelled(error: DatabaseError) {}
        })

        // Listen to distance alerts
        distanceAlertListener = ref.child("distanceAlerts").addValueEventListener(object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val alertsList = mutableListOf<DistanceAlert>()
                for (child in snapshot.children) {
                    val alert = child.getValue(DistanceAlert::class.java) ?: continue
                    if (!alert.resolved) {
                        alertsList.add(alert)
                    }
                }
                _activeDistanceAlerts.value = alertsList
            }

            override fun onCancelled(error: DatabaseError) {}
        })
        
        // Update basic group details
        groupListener = ref.addValueEventListener(object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                if (!snapshot.exists()) {
                    stopListening()
                    _activeGroup.value = null
                    _memberLocations.value = emptyMap()
                    _activeSOSAlerts.value = emptyList()
                    _activeMessages.value = emptyList()
                    return
                }
                val name = snapshot.child("name").getValue(String::class.java) ?: ""
                val createdBy = snapshot.child("createdBy").getValue(String::class.java) ?: ""
                val startPoint = snapshot.child("startPoint").getValue(String::class.java) ?: ""
                val destination = snapshot.child("destination").getValue(String::class.java) ?: ""
                val nextStopPoint = snapshot.child("nextStopPoint").getValue(String::class.java) ?: ""
                
                val waitReqs = mutableMapOf<String, WaitRequest>()
                val waitReqSnapshot = snapshot.child("waitRequests")
                for (child in waitReqSnapshot.children) {
                    val key = child.key ?: continue
                    val req = child.getValue(WaitRequest::class.java) ?: continue
                    waitReqs[key] = req
                }

                val stops = mutableListOf<String>()
                val stopsSnapshot = snapshot.child("stopPoints")
                for (child in stopsSnapshot.children) {
                    val stop = child.getValue(String::class.java) ?: continue
                    stops.add(stop)
                }

                val groupTripState = snapshot.child("groupTripState").getValue(String::class.java) ?: "NOT_STARTED"

                val members = mutableMapOf<String, Boolean>()
                val membersSnapshot = snapshot.child("members")
                for (child in membersSnapshot.children) {
                    val key = child.key ?: continue
                    members[key] = true
                }

                val pending = mutableMapOf<String, String>()
                val pendingSnapshot = snapshot.child("pendingMembers")
                for (child in pendingSnapshot.children) {
                    val key = child.key ?: continue
                    val memberName = child.getValue(String::class.java) ?: "User"
                    pending[key] = memberName
                }

                _activeGroup.value = Group(
                    groupId = groupId,
                    name = name,
                    createdBy = createdBy,
                    startPoint = startPoint,
                    destination = destination,
                    nextStopPoint = nextStopPoint,
                    groupTripState = groupTripState,
                    members = members,
                    pendingMembers = pending,
                    waitRequests = waitReqs,
                    stopPoints = stops
                )

                // If this user is approved but hasn't uploaded their details yet, trigger uploadSavedVehicleProfile
                val myLoc = _memberLocations.value[currentUserId]
                if (members.containsKey(currentUserId) && (myLoc == null || myLoc.phoneNumber.isBlank())) {
                    repositoryScope.launch {
                        uploadSavedVehicleProfile(groupId)
                    }
                }
            }

            override fun onCancelled(error: DatabaseError) {}
        })
    }

    private suspend fun uploadSavedVehicleProfile(groupId: String) {
        try {
            val prefs = context.getSharedPreferences("coroute_prefs", android.content.Context.MODE_PRIVATE)
            val vehicleType = prefs.getString("vehicle_type", "") ?: ""
            val vehicleNo = prefs.getString("vehicle_no", "") ?: ""
            val vehicleColor = prefs.getString("vehicle_color", "") ?: ""
            val emergencyContact = prefs.getString("emergency_contact", "") ?: ""
            val isCoRiding = prefs.getBoolean("is_co_riding", false)
            val ridingWithUserId = prefs.getString("riding_with_user_id", "") ?: ""
            val ridingWithUserName = prefs.getString("riding_with_user_name", "") ?: ""
            val vehicleModel = prefs.getString("vehicle_model", "") ?: ""
            val emergencyContactName = prefs.getString("emergency_contact_name", "") ?: ""
            val userPhone = prefs.getString("user_phone", "") ?: ""
            val currentTripState = prefs.getString("trip_state", "NOT_STARTED") ?: "NOT_STARTED"

            val ref = database.getReference("groups").child(groupId).child("locations").child(currentUserId)
            val updates = mapOf(
                "userName" to currentUserName,
                "isCoRiding" to isCoRiding,
                "ridingWithUserId" to ridingWithUserId,
                "ridingWithUserName" to ridingWithUserName,
                "vehicleType" to vehicleType,
                "vehicleNo" to vehicleNo,
                "vehicleColor" to vehicleColor,
                "emergencyContact" to emergencyContact,
                "phoneNumber" to userPhone,
                "tripState" to currentTripState,
                "vehicleModel" to vehicleModel,
                "emergencyContactName" to emergencyContactName
            )
            ref.updateChildren(updates).await()

            // Update groups/{groupId}/members/{userId}
            val memberRef = database.getReference("groups").child(groupId).child("members").child(currentUserId)
            val memberUpdates = mapOf(
                "tripState" to currentTripState,
                "vehicleNumber" to vehicleNo,
                "lastUpdated" to System.currentTimeMillis()
            )
            memberRef.updateChildren(memberUpdates).await()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopListening() {
        groupRef?.let { ref ->
            locationListener?.let { ref.child("locations").removeEventListener(it) }
            alertListener?.let { ref.child("alerts").removeEventListener(it) }
            messageListener?.let { ref.child("messages").removeEventListener(it) }
            distanceAlertListener?.let { ref.child("distanceAlerts").removeEventListener(it) }
            groupListener?.let { ref.removeEventListener(it) }
        }
        locationListener = null
        alertListener = null
        messageListener = null
        distanceAlertListener = null
        groupListener = null
        groupRef = null
    }
}
