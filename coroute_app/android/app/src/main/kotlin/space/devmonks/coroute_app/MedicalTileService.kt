package space.devmonks.coroute_app

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * Android Quick Settings Tile for Emergency Medical ID & First Responder ICE Card.
 *
 * Allows bystanders, paramedics, and first responders to access critical medical
 * data (Blood Group, Allergies, ICE Contacts, 112 Dial button) directly from the
 * pull-down notification shade, even when the device is locked, without requiring PIN/fingerprint.
 */
@RequiresApi(Build.VERSION_CODES.N)
class MedicalTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean("flutter.medical_enabled", true)
        val bloodGroup = prefs.getString("flutter.medical_blood_group", "") ?: ""

        tile.state = if (enabled) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Medical ID"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (bloodGroup.isNotEmpty()) "Blood: $bloodGroup" else "Emergency ICE"
        }
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MedicalIdActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) { // Android 14+
            val pendingIntent = PendingIntent.getActivity(
                this,
                101,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
