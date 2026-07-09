package com.example.travelsafetyapp.domain.repository

import com.example.travelsafetyapp.domain.model.Group
import com.example.travelsafetyapp.domain.model.GroupMessage
import com.example.travelsafetyapp.domain.model.MemberLocation
import com.example.travelsafetyapp.domain.model.SOSAlert
import kotlinx.coroutines.flow.StateFlow

interface GroupRepository {
    val activeGroup: StateFlow<Group?>
    val memberLocations: StateFlow<Map<String, MemberLocation>>
    val activeSOSAlerts: StateFlow<List<SOSAlert>>
    val activeMessages: StateFlow<List<GroupMessage>>
    val currentUserId: String
    
    suspend fun createGroup(groupName: String, creatorName: String, startPoint: String, destination: String, nextStopPoint: String): Result<String>
    suspend fun joinGroup(groupId: String, memberName: String): Result<Boolean>
    suspend fun leaveGroup(): Result<Boolean>
    suspend fun updateLocation(location: MemberLocation): Result<Boolean>
    suspend fun triggerSOS(latitude: Double, longitude: Double, targetUserId: String = ""): Result<Boolean>
    suspend fun resolveSOS(alertId: String): Result<Boolean>
    suspend fun updateVehicleProfile(
        vehicleType: String,
        vehicleNo: String,
        vehicleColor: String,
        emergencyContact: String,
        isCoRiding: Boolean = false,
        ridingWithUserId: String = "",
        ridingWithUserName: String = ""
    ): Result<Boolean>
    suspend fun updateNextStop(nextStopPoint: String): Result<Boolean>
    suspend fun requestWait(waitMinutes: Int): Result<Boolean>
    suspend fun resolveWaitRequest(userId: String): Result<Boolean>
    suspend fun assignRidingRole(userId: String, role: String): Result<Boolean>
    suspend fun sendGroupMessage(content: String, priority: String): Result<Boolean>
    suspend fun addStopPoint(stopName: String): Result<Boolean>
    suspend fun removeStopPoint(index: Int): Result<Boolean>
    suspend fun endTrip(): Result<Boolean>
}
