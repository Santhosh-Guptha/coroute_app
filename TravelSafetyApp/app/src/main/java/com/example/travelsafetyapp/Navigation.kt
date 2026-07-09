package com.example.travelsafetyapp

import android.content.Intent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import com.example.travelsafetyapp.ui.screen.DashboardScreen
import com.example.travelsafetyapp.ui.screen.JoinCreateScreen
import com.example.travelsafetyapp.ui.viewmodel.GroupViewModel

@Composable
fun MainNavigation(
    viewModel: GroupViewModel = viewModel()
) {
    val backStack = rememberNavBackStack(JoinCreate)
    val activeSOSAlerts by viewModel.activeSOSAlerts.collectAsState()
    val context = LocalContext.current

    // Launch SOSActivity over lock screen if a new alert arrives from another member
    LaunchedEffect(activeSOSAlerts) {
        val latestAlert = activeSOSAlerts.lastOrNull()
        if (latestAlert != null && latestAlert.alertId != "local_self_test") {
            val isTargeted = latestAlert.targetUserId.isNotBlank()
            val shouldAlert = if (isTargeted) {
                latestAlert.targetUserId == viewModel.currentUserId
            } else {
                latestAlert.userId != viewModel.currentUserId
            }
            if (shouldAlert) {
                val intent = Intent(context, SOSActivity::class.java).apply {
                    putExtra(SOSActivity.EXTRA_SENDER_NAME, latestAlert.userName)
                    putExtra(SOSActivity.EXTRA_LATITUDE, latestAlert.latitude)
                    putExtra(SOSActivity.EXTRA_LONGITUDE, latestAlert.longitude)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                context.startActivity(intent)
            }
        }
    }

    NavDisplay(
        backStack = backStack,
        onBack = { backStack.removeLastOrNull() },
        entryProvider = entryProvider {
            entry<JoinCreate> {
                JoinCreateScreen(
                    viewModel = viewModel,
                    onNavigateToDashboard = {
                        backStack.add(Dashboard)
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }
            entry<Dashboard> {
                DashboardScreen(
                    viewModel = viewModel,
                    onNavigateBack = {
                        backStack.removeLastOrNull()
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
    )
}
