package com.example.travelsafetyapp.ui.viewmodel

import android.app.Application
import android.content.Context
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.travelsafetyapp.data.RepositoryProvider
import com.example.travelsafetyapp.domain.model.Group
import com.example.travelsafetyapp.domain.model.GroupMessage
import com.example.travelsafetyapp.domain.model.MemberLocation
import com.example.travelsafetyapp.domain.model.SOSAlert
import com.example.travelsafetyapp.domain.model.TripHistory
import com.example.travelsafetyapp.service.TrackingService
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

class GroupViewModel(application: Application) : AndroidViewModel(application) {
    
    private val groupRepository = RepositoryProvider.getGroupRepository()

    val activeGroup: StateFlow<Group?> = groupRepository.activeGroup
    val memberLocations: StateFlow<Map<String, MemberLocation>> = groupRepository.memberLocations
    val activeSOSAlerts: StateFlow<List<SOSAlert>> = groupRepository.activeSOSAlerts
    val activeMessages: StateFlow<List<GroupMessage>> = groupRepository.activeMessages
    val currentUserId: String get() = groupRepository.currentUserId

    private val _isServiceRunning = MutableStateFlow(false)
    val isServiceRunning: StateFlow<Boolean> = _isServiceRunning.asStateFlow()

    private val _isSimulationMode = MutableStateFlow(RepositoryProvider.isSimulationMode())
    val isSimulationMode: StateFlow<Boolean> = _isSimulationMode.asStateFlow()

    private val _errorState = MutableStateFlow<String?>(null)
    val errorState: StateFlow<String?> = _errorState.asStateFlow()

    private val prefs = application.getSharedPreferences("coroute_prefs", Context.MODE_PRIVATE)
    
    val isGmailVerified = MutableStateFlow(prefs.getBoolean("gmail_verified", false))
    val verifiedEmail = MutableStateFlow(prefs.getString("verified_email", "") ?: "")
    val isProfileCompleted = MutableStateFlow(prefs.getBoolean("profile_completed", false))

    val themeMode = MutableStateFlow(prefs.getString("theme_mode", "Time") ?: "Time")
    private val _isDarkTheme = MutableStateFlow(false)
    val isDarkTheme: StateFlow<Boolean> = _isDarkTheme.asStateFlow()

    private val _tripHistory = MutableStateFlow<List<TripHistory>>(emptyList())
    val tripHistory: StateFlow<List<TripHistory>> = _tripHistory.asStateFlow()
    
    private var currentOtp: String? = null
    
    fun setGmailVerified(email: String) {
        prefs.edit()
            .putBoolean("gmail_verified", true)
            .putString("verified_email", email)
            .apply()
        isGmailVerified.value = true
        verifiedEmail.value = email
    }

    fun checkIsDarkTheme(): Boolean {
        return when (themeMode.value) {
            "Light" -> false
            "Dark" -> true
            else -> { // "Time"
                val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
                hour >= 18 || hour < 6 // Dark from 6 PM to 6 AM
            }
        }
    }

    fun setThemeMode(mode: String) {
        prefs.edit().putString("theme_mode", mode).apply()
        themeMode.value = mode
        _isDarkTheme.value = checkIsDarkTheme()
    }

    fun sendOtpVerification(email: String, onComplete: (Result<Boolean>) -> Unit) {
        viewModelScope.launch {
            val otp = (100000..999999).random().toString()
            currentOtp = otp
            val result = com.example.travelsafetyapp.service.MailSender.sendOtpEmail(email, otp)
            onComplete(result)
        }
    }

    fun verifyOtp(enteredOtp: String): Boolean {
        return enteredOtp == currentOtp && currentOtp != null
    }

    fun saveActiveGroupId(groupId: String?) {
        prefs.edit().putString("active_group_id", groupId).apply()
    }

    fun getSavedGroupId(): String? {
        return prefs.getString("active_group_id", null)
    }

    private fun loadTripHistory() {
        val historyJson = prefs.getString("trip_history", "[]") ?: "[]"
        try {
            val arr = JSONArray(historyJson)
            val list = mutableListOf<TripHistory>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                list.add(
                    TripHistory(
                        groupId = obj.optString("groupId", ""),
                        tripName = obj.optString("tripName", ""),
                        startPoint = obj.optString("startPoint", ""),
                        destination = obj.optString("destination", ""),
                        memberCount = obj.optInt("memberCount", 0),
                        createdAt = obj.optLong("createdAt", 0L),
                        endedAt = obj.optLong("endedAt", 0L)
                    )
                )
            }
            _tripHistory.value = list.sortedByDescending { it.endedAt }
        } catch (_: Exception) {
            _tripHistory.value = emptyList()
        }
    }

    private fun saveTripToHistory(group: Group) {
        val current = _tripHistory.value.toMutableList()
        val existingIndex = current.indexOfFirst { it.groupId == group.groupId }
        val newTrip = TripHistory(
            groupId = group.groupId,
            tripName = group.name,
            startPoint = group.startPoint,
            destination = group.destination,
            memberCount = group.members.size,
            createdAt = 0L,
            endedAt = System.currentTimeMillis()
        )
        if (existingIndex != -1) {
            current[existingIndex] = newTrip
        } else {
            current.add(0, newTrip)
        }
        _tripHistory.value = current
        // Save to prefs
        val arr = JSONArray()
        current.forEach { t ->
            arr.put(JSONObject().apply {
                put("groupId", t.groupId)
                put("tripName", t.tripName)
                put("startPoint", t.startPoint)
                put("destination", t.destination)
                put("memberCount", t.memberCount)
                put("createdAt", t.createdAt)
                put("endedAt", t.endedAt)
            })
        }
        prefs.edit().putString("trip_history", arr.toString()).apply()
    }

    init {
        RepositoryProvider.initialize(application)
        _isSimulationMode.value = RepositoryProvider.isSimulationMode()
        loadTripHistory()
        _isDarkTheme.value = checkIsDarkTheme()
        
        // Attempt to auto-restore saved group session with correct display name
        getSavedGroupId()?.let { savedId ->
            val savedDisplayName = prefs.getString("saved_user_display_name", null) 
                ?: prefs.getString("verified_email", "User") 
                ?: "User"
            viewModelScope.launch {
                groupRepository.joinGroup(savedId, savedDisplayName)
            }
        }

        // Auto-cleanup on backend group deletion/end
        viewModelScope.launch {
            activeGroup.collect { group ->
                if (group == null && getSavedGroupId() != null) {
                    stopTrackingService()
                    saveActiveGroupId(null)
                }
            }
        }
    }

    fun saveUserDisplayName(name: String) {
        prefs.edit().putString("saved_user_display_name", name).apply()
    }

    fun getSavedDisplayName(): String? {
        return prefs.getString("saved_user_display_name", null)
    }

    fun toggleSimulationMode(enabled: Boolean) {
        viewModelScope.launch {
            if (activeGroup.value != null) {
                leaveGroup()
            }
            RepositoryProvider.setSimulationMode(enabled)
            _isSimulationMode.value = enabled
            val newRepo = RepositoryProvider.getGroupRepository()
        }
    }

    fun createGroup(
        groupName: String,
        creatorName: String,
        startPoint: String,
        destination: String,
        nextStopPoint: String,
        onSuccess: (String) -> Unit
    ) {
        if (activeGroup.value != null) {
            _errorState.value = "You are already in an active group. Please leave or complete your active trip first."
            return
        }
        viewModelScope.launch {
            _errorState.value = null
            val result = RepositoryProvider.getGroupRepository().createGroup(
                groupName, creatorName, startPoint, destination, nextStopPoint
            )
            result.fold(
                onSuccess = { groupId ->
                    saveActiveGroupId(groupId)
                    saveUserDisplayName(creatorName)
                    onSuccess(groupId)
                },
                onFailure = { throwable ->
                    _errorState.value = "Failed to create group: ${throwable.localizedMessage}"
                }
            )
        }
    }

    fun joinGroup(groupId: String, memberName: String, onSuccess: () -> Unit) {
        if (activeGroup.value != null) {
            _errorState.value = "You are already in an active group. Please leave or complete your active trip first."
            return
        }
        viewModelScope.launch {
            _errorState.value = null
            val result = RepositoryProvider.getGroupRepository().joinGroup(groupId, memberName)
            result.fold(
                onSuccess = {
                    saveActiveGroupId(groupId)
                    saveUserDisplayName(memberName)
                    onSuccess()
                },
                onFailure = { throwable ->
                    _errorState.value = "Failed to join group: ${throwable.localizedMessage}"
                }
            )
        }
    }

    fun leaveGroup() {
        viewModelScope.launch {
            stopTrackingService()
            saveActiveGroupId(null)
            RepositoryProvider.getGroupRepository().leaveGroup()
        }
    }

    fun startTrackingService() {
        val context = getApplication<Application>()
        val intent = Intent(context, TrackingService::class.java).apply {
            action = TrackingService.ACTION_START
            putExtra(TrackingService.EXTRA_GROUP_ID, getSavedGroupId())
            putExtra(TrackingService.EXTRA_USER_ID, currentUserId)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
        _isServiceRunning.value = true
    }

    fun stopTrackingService() {
        val context = getApplication<Application>()
        val intent = Intent(context, TrackingService::class.java).apply {
            action = TrackingService.ACTION_STOP
        }
        context.startService(intent)
        _isServiceRunning.value = false
    }

    fun triggerSOS(targetUserId: String = "") {
        viewModelScope.launch {
            val group = activeGroup.value ?: return@launch
            val myLoc = memberLocations.value[currentUserId] ?: memberLocations.value.values.firstOrNull()
            val lat = myLoc?.lat ?: 15.4909
            val lng = myLoc?.lng ?: 73.8278
            
            RepositoryProvider.getGroupRepository().triggerSOS(lat, lng, targetUserId)
        }
    }

    fun resolveSOS(alertId: String) {
        viewModelScope.launch {
            RepositoryProvider.getGroupRepository().resolveSOS(alertId)
        }
    }

    fun updateVehicleProfile(
        vehicleType: String,
        vehicleNo: String,
        vehicleColor: String,
        emergencyContact: String,
        isCoRiding: Boolean = false,
        ridingWithUserId: String = "",
        ridingWithUserName: String = "",
        onComplete: (Boolean) -> Unit = {}
    ) {
        viewModelScope.launch {
            val result = RepositoryProvider.getGroupRepository().updateVehicleProfile(
                vehicleType, vehicleNo, vehicleColor, emergencyContact, isCoRiding, ridingWithUserId, ridingWithUserName
            )
            if (result.isSuccess) {
                prefs.edit().putBoolean("profile_completed", true).apply()
                isProfileCompleted.value = true
            }
            onComplete(result.isSuccess)
        }
    }

    fun togglePauseTracking(paused: Boolean) {
        viewModelScope.launch {
            val repo = RepositoryProvider.getGroupRepository()
            val currentLoc = memberLocations.value[currentUserId] ?: MemberLocation(userName = verifiedEmail.value)
            val updatedLoc = currentLoc.copy(isPaused = paused)
            repo.updateLocation(updatedLoc)
        }
    }

    fun endTrip(onSuccess: () -> Unit) {
        viewModelScope.launch {
            // Save to history before ending
            activeGroup.value?.let { saveTripToHistory(it) }
            stopTrackingService()
            val result = RepositoryProvider.getGroupRepository().endTrip()
            result.fold(
                onSuccess = {
                    saveActiveGroupId(null)
                    onSuccess()
                },
                onFailure = { throwable ->
                    _errorState.value = "Failed to end trip: ${throwable.localizedMessage}"
                }
            )
        }
    }

    fun updateNextStop(nextStopPoint: String) {
        viewModelScope.launch {
            RepositoryProvider.getGroupRepository().updateNextStop(nextStopPoint)
        }
    }

    fun addStopPoint(stopName: String) {
        viewModelScope.launch {
            RepositoryProvider.getGroupRepository().addStopPoint(stopName)
        }
    }

    fun removeStopPoint(index: Int) {
        viewModelScope.launch {
            RepositoryProvider.getGroupRepository().removeStopPoint(index)
        }
    }

    fun requestWait(waitMinutes: Int) {
        viewModelScope.launch {
            RepositoryProvider.getGroupRepository().requestWait(waitMinutes)
        }
    }

    fun resolveWaitRequest(userId: String) {
        viewModelScope.launch {
            RepositoryProvider.getGroupRepository().resolveWaitRequest(userId)
        }
    }

    fun assignRidingRole(userId: String, role: String) {
        viewModelScope.launch {
            RepositoryProvider.getGroupRepository().assignRidingRole(userId, role)
        }
    }

    fun sendGroupMessage(content: String, priority: String) {
        viewModelScope.launch {
            RepositoryProvider.getGroupRepository().sendGroupMessage(content, priority)
        }
    }

    fun clearError() {
        _errorState.value = null
    }
}
