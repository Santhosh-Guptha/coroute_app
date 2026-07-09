package com.example.travelsafetyapp.domain.model

import kotlinx.serialization.Serializable

@Serializable
data class MemberLocation(
    val lat: Double = 0.0,
    val lng: Double = 0.0,
    val speed: Float = 0f,
    val battery: Int = 100,
    val lastUpdated: Long = 0L,
    val userName: String = "",
    val vehicleType: String = "",
    val vehicleNo: String = "",
    val vehicleColor: String = "",
    val emergencyContact: String = "",
    val ridingRole: String = "",
    val routeHistory: Map<String, LatLngPoint> = emptyMap(),
    val isCoRiding: Boolean = false,
    val ridingWithUserId: String = "",
    val ridingWithUserName: String = "",
    val isPaused: Boolean = false,
    val tripState: String = "NOT_STARTED",
    val phoneNumber: String = "",
    val vehicleModel: String = "",
    val emergencyContactName: String = ""
)

@Serializable
data class LatLngPoint(
    val lat: Double = 0.0,
    val lng: Double = 0.0
)

@Serializable
data class SOSAlert(
    val alertId: String = "",
    val userId: String = "",
    val userName: String = "",
    val timestamp: Long = 0L,
    val resolved: Boolean = false,
    val latitude: Double = 0.0,
    val longitude: Double = 0.0,
    val targetUserId: String = "",
    val type: String = "SOS",
    val triggeredBy: String = ""
)

@Serializable
data class WaitRequest(
    val userId: String = "",
    val userName: String = "",
    val waitMinutes: Int = 0,
    val timestamp: Long = 0L
)

@Serializable
data class GroupMessage(
    val messageId: String = "",
    val senderId: String = "",
    val senderName: String = "",
    val content: String = "",
    val priority: String = "Medium",
    val timestamp: Long = 0L
)

@Serializable
data class DistanceAlert(
    val alertId: String = "",
    val userId: String = "",
    val userName: String = "",
    val distance: Double = 0.0,
    val level: String = "WARNING", // "WARNING" or "CRITICAL"
    val timestamp: Long = 0L,
    val resolved: Boolean = false
)

@Serializable
data class Group(
    val groupId: String = "",
    val name: String = "",
    val createdBy: String = "",
    val startPoint: String = "",
    val destination: String = "",
    val nextStopPoint: String = "",
    val nextStopLat: Double = 0.0,
    val nextStopLng: Double = 0.0,
    val groupTripState: String = "NOT_STARTED",
    val members: Map<String, Boolean> = emptyMap(),
    val pendingMembers: Map<String, String> = emptyMap(),
    val locations: Map<String, MemberLocation> = emptyMap(),
    val alerts: Map<String, SOSAlert> = emptyMap(),
    val waitRequests: Map<String, WaitRequest> = emptyMap(),
    val messages: Map<String, GroupMessage> = emptyMap(),
    val distanceAlerts: Map<String, DistanceAlert> = emptyMap(),
    val stopPoints: List<String> = emptyList()
)

@Serializable
data class TripHistory(
    val groupId: String = "",
    val tripName: String = "",
    val startPoint: String = "",
    val destination: String = "",
    val memberCount: Int = 0,
    val createdAt: Long = 0L,
    val endedAt: Long = 0L
)
