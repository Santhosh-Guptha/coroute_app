package com.example.travelsafetyapp

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
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
        val permissionLauncher = rememberLauncherForActivityResult(
            contract = ActivityResultContracts.RequestMultiplePermissions(),
            onResult = { permissions ->
                // Handle results if needed
            }
        )

        LaunchedEffect(Unit) {
            permissionLauncher.launch(
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                )
            )
        }

        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { 
            MainNavigation() 
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
