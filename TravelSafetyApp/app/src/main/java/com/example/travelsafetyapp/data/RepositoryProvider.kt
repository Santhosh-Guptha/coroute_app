package com.example.travelsafetyapp.data

import android.content.Context
import com.example.travelsafetyapp.data.repository.FirebaseGroupRepository
import com.example.travelsafetyapp.data.repository.MockGroupRepository
import com.example.travelsafetyapp.domain.repository.GroupRepository
import com.google.firebase.FirebaseApp

object RepositoryProvider {
    private var activeRepository: GroupRepository? = null
    private var appContext: Context? = null

    fun initialize(context: Context) {
        appContext = context.applicationContext
        checkFirebaseConfigured(context)
    }

    fun isSimulationMode(): Boolean = false

    fun setSimulationMode(enabled: Boolean) {
        // No-op
    }

    fun getGroupRepository(): GroupRepository {
        activeRepository?.let { return it }
        val repo = FirebaseGroupRepository(appContext ?: throw IllegalStateException("RepositoryProvider not initialized"))
        activeRepository = repo
        return repo
    }

    private fun checkFirebaseConfigured(context: Context): Boolean {
        return try {
            if (FirebaseApp.getApps(context).isNotEmpty()) {
                return true
            }
            // Check if resources from google-services.json are generated
            val resId = context.resources.getIdentifier("google_app_id", "string", context.packageName)
            if (resId != 0) {
                FirebaseApp.initializeApp(context)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            false
        }
    }
}
