package com.example.travelsafetyapp.data.repository

import com.example.travelsafetyapp.domain.model.Group
import com.example.travelsafetyapp.domain.model.MemberLocation
import com.example.travelsafetyapp.domain.model.DistanceAlert
import com.example.travelsafetyapp.domain.model.GroupMessage
import com.example.travelsafetyapp.domain.model.SOSAlert
import com.example.travelsafetyapp.domain.model.WaitRequest
import com.example.travelsafetyapp.domain.model.LatLngPoint
import com.example.travelsafetyapp.domain.repository.GroupRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import kotlin.random.Random

class MockGroupRepository : GroupRepository {
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private var simulationJob: Job? = null

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

    override val currentUserId: String = "user_me"
    private var currentUserName: String = "You"

    override suspend fun createGroup(
        groupName: String,
        creatorName: String,
        startPoint: String,
        destination: String,
        nextStopPoint: String
    ): Result<String> {
        delay(500)
        val groupId = (100000..999999).random().toString()
        currentUserName = creatorName
        val group = Group(
            groupId = groupId,
            name = groupName,
            createdBy = currentUserId,
            startPoint = startPoint,
            destination = destination,
            nextStopPoint = nextStopPoint,
            members = mapOf(currentUserId to true)
        )
        _activeGroup.value = group
        startSimulation(groupId)
        return Result.success(groupId)
    }

    override suspend fun joinGroup(groupId: String, memberName: String): Result<Boolean> {
        delay(500)
        currentUserName = memberName
        val group = Group(
            groupId = groupId,
            name = "Adventure Trek Group",
            createdBy = "user_1",
            members = mapOf(
                currentUserId to true,
                "user_1" to true,
                "user_2" to true,
                "user_3" to true
            )
        )
        _activeGroup.value = group
        startSimulation(groupId)
        return Result.success(true)
    }

    override suspend fun leaveGroup(): Result<Boolean> {
        stopSimulation()
        _activeGroup.value = null
        _memberLocations.value = emptyMap()
        _activeSOSAlerts.value = emptyList()
        _activeMessages.value = emptyList()
        _activeDistanceAlerts.value = emptyList()
        return Result.success(true)
    }

    override suspend fun updateLocation(location: MemberLocation): Result<Boolean> {
        val group = _activeGroup.value ?: return Result.failure(Exception("Not in a group"))
        val updatedLocs = _memberLocations.value.toMutableMap()
        
        val currentLoc = updatedLocs[currentUserId]
        val hist = (currentLoc?.routeHistory ?: emptyMap()).toMutableMap()
        val lastPoint = hist.values.lastOrNull()
        if (lastPoint == null || lastPoint.lat != location.lat || lastPoint.lng != location.lng) {
            val key = UUID.randomUUID().toString()
            hist[key] = LatLngPoint(location.lat, location.lng)
        }
        
        updatedLocs[currentUserId] = location.copy(
            userName = currentUserName,
            routeHistory = hist,
            vehicleType = currentLoc?.vehicleType ?: "",
            vehicleNo = currentLoc?.vehicleNo ?: "",
            vehicleColor = currentLoc?.vehicleColor ?: "",
            emergencyContact = currentLoc?.emergencyContact ?: "",
            ridingRole = currentLoc?.ridingRole ?: "",
            isCoRiding = currentLoc?.isCoRiding ?: false,
            ridingWithUserId = currentLoc?.ridingWithUserId ?: "",
            ridingWithUserName = currentLoc?.ridingWithUserName ?: "",
            isPaused = location.isPaused
        )
        _memberLocations.value = updatedLocs
        
        // Keep group locations mapping in sync
        _activeGroup.value = group.copy(locations = updatedLocs)
        return Result.success(true)
    }

    override suspend fun triggerSOS(latitude: Double, longitude: Double, targetUserId: String, type: String, triggeredBy: String): Result<Boolean> {
        val alert = SOSAlert(
            alertId = java.util.UUID.randomUUID().toString(),
            userId = currentUserId,
            userName = currentUserName,
            timestamp = System.currentTimeMillis(),
            latitude = latitude,
            longitude = longitude,
            targetUserId = targetUserId,
            type = type,
            triggeredBy = triggeredBy.ifBlank { currentUserId }
        )
        val updatedAlerts = _activeSOSAlerts.value.toMutableList()
        updatedAlerts.add(alert)
        _activeSOSAlerts.value = updatedAlerts
        return Result.success(true)
    }

    override suspend fun resolveSOS(alertId: String): Result<Boolean> {
        val updatedAlerts = _activeSOSAlerts.value.filterNot { it.alertId == alertId }
        _activeSOSAlerts.value = updatedAlerts
        return Result.success(true)
    }

    private fun startSimulation(groupId: String) {
        stopSimulation()
        simulationJob = scope.launch {
            // Initial coordinates representing Trekking area (e.g. Goa/Western Ghats region)
            var baseLat = 15.4909
            var baseLng = 73.8278

            // Mock members
            val mockMembers = listOf(
                MockMember("user_1", "Aditya", 15.4925, 73.8290, 89),
                MockMember("user_2", "Neha", 15.4890, 73.8255, 74),
                MockMember("user_3", "Rahul", 15.4950, 73.8320, 95)
            )

            // Populate initial positions (Only me, mock members join later!)
            val initialLocs = _memberLocations.value.toMutableMap()
            initialLocs.remove("user_1")
            initialLocs.remove("user_2")
            initialLocs.remove("user_3")
            _memberLocations.value = initialLocs

            var iteration = 0
            while (isActive) {
                delay(3000) // Update every 3 seconds
                iteration++

                // Update my base position if available to keep mock users close
                _memberLocations.value[currentUserId]?.let { myLoc ->
                    baseLat = myLoc.lat
                    baseLng = myLoc.lng
                }

                // Simulate subtle movement for mock members
                val updatedLocs = _memberLocations.value.toMutableMap()
                
                val activeMockMembers = mutableListOf<MockMember>()
                if (iteration >= 2) activeMockMembers.add(mockMembers[0]) // Aditya joins
                if (iteration >= 4) activeMockMembers.add(mockMembers[1]) // Neha joins
                if (iteration >= 6) activeMockMembers.add(mockMembers[2]) // Rahul joins

                activeMockMembers.forEach { member ->
                    // Get current or use base with offset
                    val currentLoc = updatedLocs[member.id] ?: MemberLocation(
                        lat = member.lat, 
                        lng = member.lng, 
                        userName = member.name,
                        battery = member.battery
                    )
                    
                    // Add random walk offset
                    val newLat = if (updatedLocs[member.id] != null) currentLoc.lat + (Random.nextDouble(-0.0002, 0.0002)) else member.lat
                    val newLng = if (updatedLocs[member.id] != null) currentLoc.lng + (Random.nextDouble(-0.0002, 0.0002)) else member.lng
                    val speed = Random.nextDouble(2.0, 6.5).toFloat()
                    val batteryDrop = if (Random.nextDouble() > 0.9) 1 else 0
                    val newBattery = (currentLoc.battery - batteryDrop).coerceAtLeast(5)

                    val hist = currentLoc.routeHistory.toMutableMap()
                    val key = UUID.randomUUID().toString()
                    hist[key] = LatLngPoint(newLat, newLng)

                    updatedLocs[member.id] = MemberLocation(
                        lat = newLat,
                        lng = newLng,
                        speed = speed,
                        battery = newBattery,
                        lastUpdated = System.currentTimeMillis(),
                        userName = member.name,
                        routeHistory = hist
                    )
                }
                _memberLocations.value = updatedLocs

                // Trigger a simulated SOS alert from Neha at iteration 10 to demonstrate alert UI
                if (iteration == 10 && _activeSOSAlerts.value.isEmpty()) {
                    val targetLoc = updatedLocs["user_2"] ?: MemberLocation(lat = 15.4890, lng = 73.8255)
                    val mockAlert = SOSAlert(
                        alertId = "mock_alert_neha",
                        userId = "user_2",
                        userName = "Neha",
                        timestamp = System.currentTimeMillis(),
                        latitude = targetLoc.lat,
                        longitude = targetLoc.lng
                    )
                    _activeSOSAlerts.value = _activeSOSAlerts.value + mockAlert
                }
            }
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
        val currentLoc = _memberLocations.value[currentUserId] ?: MemberLocation(userName = currentUserName)
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
            emergencyContactName = emergencyContactName,
            isPaused = currentLoc.isPaused
        )
        val updatedLocs = _memberLocations.value.toMutableMap()
        updatedLocs[currentUserId] = updatedLoc
        _memberLocations.value = updatedLocs
        return Result.success(true)
    }

    override suspend fun updateNextStop(nextStopPoint: String): Result<Boolean> {
        val group = _activeGroup.value ?: return Result.failure(Exception("No active group"))
        _activeGroup.value = group.copy(nextStopPoint = nextStopPoint)
        return Result.success(true)
    }

    override suspend fun addStopPoint(stopName: String): Result<Boolean> {
        val group = _activeGroup.value ?: return Result.failure(Exception("No active group"))
        val updatedStops = group.stopPoints.toMutableList().apply { add(stopName) }
        _activeGroup.value = group.copy(stopPoints = updatedStops)
        return Result.success(true)
    }

    override suspend fun removeStopPoint(index: Int): Result<Boolean> {
        val group = _activeGroup.value ?: return Result.failure(Exception("No active group"))
        val updatedStops = group.stopPoints.toMutableList()
        if (index in updatedStops.indices) {
            updatedStops.removeAt(index)
            _activeGroup.value = group.copy(stopPoints = updatedStops)
            return Result.success(true)
        }
        return Result.failure(IndexOutOfBoundsException("Index $index out of bounds"))
    }

    override suspend fun requestWait(waitMinutes: Int): Result<Boolean> {
        val group = _activeGroup.value ?: return Result.failure(Exception("No active group"))
        val req = WaitRequest(
            userId = currentUserId,
            userName = currentUserName,
            waitMinutes = waitMinutes,
            timestamp = System.currentTimeMillis()
        )
        val updatedRequests = group.waitRequests.toMutableMap()
        updatedRequests[currentUserId] = req
        _activeGroup.value = group.copy(waitRequests = updatedRequests)
        return Result.success(true)
    }

    override suspend fun resolveWaitRequest(userId: String): Result<Boolean> {
        val group = _activeGroup.value ?: return Result.failure(Exception("No active group"))
        val updatedRequests = group.waitRequests.toMutableMap()
        updatedRequests.remove(userId)
        _activeGroup.value = group.copy(waitRequests = updatedRequests)
        return Result.success(true)
    }

    override suspend fun assignRidingRole(userId: String, role: String): Result<Boolean> {
        val targetRole = role.uppercase()
        
        // Enforce unique LEAD/SWEEP roles
        val updatedLocs = _memberLocations.value.toMutableMap()
        if (targetRole == "LEAD" || targetRole == "SWEEP") {
            updatedLocs.forEach { (uid, loc) ->
                if (uid != userId && loc.ridingRole.uppercase() == targetRole) {
                    updatedLocs[uid] = loc.copy(ridingRole = "MIDDLE")
                }
            }
        }
        
        val currentLoc = updatedLocs[userId] ?: return Result.failure(Exception("Member location not found"))
        updatedLocs[userId] = currentLoc.copy(ridingRole = targetRole)
        _memberLocations.value = updatedLocs
        return Result.success(true)
    }

    override suspend fun triggerDistanceAlert(alert: DistanceAlert): Result<Boolean> {
        _activeDistanceAlerts.value = _activeDistanceAlerts.value + alert
        return Result.success(true)
    }

    override suspend fun resolveDistanceAlert(alertId: String): Result<Boolean> {
        _activeDistanceAlerts.value = _activeDistanceAlerts.value.filter { it.alertId != alertId }
        return Result.success(true)
    }

    override suspend fun sendGroupMessage(content: String, priority: String): Result<Boolean> {
        val group = _activeGroup.value ?: return Result.failure(Exception("No active group"))
        val message = GroupMessage(
            messageId = UUID.randomUUID().toString(),
            senderId = currentUserId,
            senderName = currentUserName,
            content = content,
            priority = priority,
            timestamp = System.currentTimeMillis()
        )
        _activeMessages.value = _activeMessages.value + message
        return Result.success(true)
    }

    override suspend fun updateGroupTripState(state: String): Result<Boolean> = Result.success(true)
    override suspend fun approveMember(userId: String): Result<Boolean> = Result.success(true)
    override suspend fun rejectMember(userId: String): Result<Boolean> = Result.success(true)

    override suspend fun endTrip(): Result<Boolean> {
        stopSimulation()
        _activeGroup.value = null
        _memberLocations.value = emptyMap()
        _activeSOSAlerts.value = emptyList()
        _activeMessages.value = emptyList()
        _activeDistanceAlerts.value = emptyList()
        return Result.success(true)
    }

    private fun stopSimulation() {
        simulationJob?.cancel()
        simulationJob = null
    }

    private data class MockMember(
        val id: String,
        val name: String,
        val lat: Double,
        val lng: Double,
        val battery: Int
    )
}
