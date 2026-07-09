package com.example.travelsafetyapp

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.example.travelsafetyapp.theme.TravelSafetyAppTheme

class MainActivity : ComponentActivity() {

    companion object {
        // Shared state containing any incoming deep link groupId
        val deepLinkGroupId = mutableStateOf<String?>(null)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        com.example.travelsafetyapp.data.RepositoryProvider.initialize(applicationContext)
        super.onCreate(savedInstanceState)

        // Handle deep link at launch
        handleDeepLink(intent)

        enableEdgeToEdge()
        setContent {
            TravelSafetyAppTheme {
                val context = LocalContext.current

                // Permission states
                var locationGranted by remember { mutableStateOf(false) }
                var backgroundLocationGranted by remember { mutableStateOf(false) }
                var notificationGranted by remember { mutableStateOf(false) }
                var permissionsChecked by remember { mutableStateOf(false) }

                // Check initial permission states
                LaunchedEffect(Unit) {
                    locationGranted = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                    backgroundLocationGranted = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
                    notificationGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                    } else true
                }

                // Step 3: Notification permission (Android 13+)
                val notificationLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestPermission(),
                    onResult = { granted ->
                        notificationGranted = granted
                        permissionsChecked = true
                    }
                )

                // Step 2: Background location permission (must be requested separately after foreground)
                val backgroundLocationLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestPermission(),
                    onResult = { granted ->
                        backgroundLocationGranted = granted
                        // Now request notifications
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                        } else {
                            notificationGranted = true
                            permissionsChecked = true
                        }
                    }
                )

                // Step 1: Foreground location permissions
                val locationLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestMultiplePermissions(),
                    onResult = { permissions ->
                        locationGranted = permissions[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                                permissions[Manifest.permission.ACCESS_COARSE_LOCATION] == true
                        // Now request background location (Android requires separate request)
                        if (locationGranted) {
                            backgroundLocationLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                        } else {
                            // Still proceed but mark as checked
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                            } else {
                                notificationGranted = true
                                permissionsChecked = true
                            }
                        }
                    }
                )

                // Launch permission request chain
                LaunchedEffect(Unit) {
                    if (!locationGranted) {
                        locationLauncher.launch(
                            arrayOf(
                                Manifest.permission.ACCESS_FINE_LOCATION,
                                Manifest.permission.ACCESS_COARSE_LOCATION
                            )
                        )
                    } else if (!backgroundLocationGranted) {
                        backgroundLocationLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !notificationGranted) {
                        notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        permissionsChecked = true
                    }
                }

                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Column(modifier = Modifier.fillMaxSize()) {
                        // Warning banners for missing permissions
                        AnimatedVisibility(visible = permissionsChecked && !locationGranted) {
                            PermissionWarningBanner(
                                text = "⚠️ Location permission denied. Tracking will not work. Please enable in Settings.",
                                color = Color(0xFFEF4444)
                            )
                        }

                        AnimatedVisibility(visible = permissionsChecked && locationGranted && !backgroundLocationGranted) {
                            PermissionWarningBanner(
                                text = "⚠️ Background location denied. Tracking may stop when app is minimized. Enable 'Allow all the time' in Settings.",
                                color = Color(0xFFF59E0B)
                            )
                        }

                        AnimatedVisibility(visible = permissionsChecked && !notificationGranted) {
                            PermissionWarningBanner(
                                text = "⚠️ Notification permission denied. You won't receive SOS alerts or messages. Enable in Settings.",
                                color = Color(0xFFF59E0B)
                            )
                        }

                        // Main app content - always shown regardless of permissions
                        Box(modifier = Modifier.weight(1f)) {
                            MainNavigation()
                        }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent?) {
        intent?.data?.let { uri ->
            if (uri.scheme == "coroute" && uri.host == "join") {
                val code = uri.getQueryParameter("groupId")
                if (!code.isNullOrBlank()) {
                    deepLinkGroupId.value = code
                }
            }
        }
    }
}

@Composable
fun PermissionWarningBanner(text: String, color: Color) {
    Surface(
        color = color.copy(alpha = 0.15f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Default.Warning,
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = text,
                color = color,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium
            )
        }
    }
}
