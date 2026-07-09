package com.example.travelsafetyapp.domain.repository

import com.example.travelsafetyapp.domain.model.MemberLocation
import kotlinx.coroutines.flow.StateFlow

interface LocationRepository {
    val currentTrackingLocation: StateFlow<MemberLocation?>
    fun startLocationUpdates(intervalSeconds: Long)
    fun stopLocationUpdates()
    fun updateTrackingInterval(intervalSeconds: Long)
}
