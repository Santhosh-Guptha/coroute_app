package space.devmonks.coroute_app

import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Agent 4: another rider's SOS over the lock screen (the full-screen intent of the urgent
 * alert posted by [RideNotification] "showUrgent").
 *
 * Shows only the alert's title and text (names, never a position) and two buttons:
 * "Open CoRoute" asks the system to unlock first (KeyguardManager.requestDismissKeyguard), so
 * nothing of the app is visible without the PIN; "Close" silences the alert (cancels the
 * notification; the alert stays in the app's Alerts screen). Not exported.
 */
class UrgentAlertActivity : Activity() {

    companion object {
        const val EXTRA_TITLE = "coroute_urgent_title"
        const val EXTRA_BODY = "coroute_urgent_body"
        const val EXTRA_ID = "coroute_urgent_id"
    }

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotEmpty() } ?: "Rider emergency"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: ""
        val id = intent?.getIntExtra(EXTRA_ID, 0) ?: 0

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.parseColor("#0F1115"))
            setPadding(dp(24), dp(32), dp(24), dp(32))
        }
        root.addView(TextView(this).apply {
            text = "SOS"
            setTextColor(Color.parseColor("#FF5252"))
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            letterSpacing = 0.2f
        })
        root.addView(TextView(this).apply {
            text = title
            setTextColor(Color.WHITE)
            textSize = 26f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(8), 0, dp(8))
        })
        if (body.isNotEmpty()) {
            root.addView(TextView(this).apply {
                text = body
                setTextColor(Color.parseColor("#CFD8DC"))
                textSize = 18f
                setPadding(0, 0, 0, dp(24))
            })
        }
        root.addView(button("Open CoRoute", "#D32F2F") { openApp(id) })
        root.addView(button("Close", "#37474F") { close(id) })
        setContentView(root)
    }

    private fun button(label: String, color: String, onClick: () -> Unit): Button {
        return Button(this).apply {
            text = label
            isAllCaps = false
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                cornerRadius = dp(28).toFloat()
                setColor(Color.parseColor(color))
            }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(56)).apply {
                topMargin = dp(12)
            }
            setOnClickListener { onClick() }
        }
    }

    /** Unlock first (never shows the app over the lock screen), then the ride map. */
    private fun openApp(id: Int) {
        val km = getSystemService(KeyguardManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && km != null && km.isKeyguardLocked) {
            km.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() {
                    launchApp(id)
                }
            })
        } else {
            launchApp(id)
        }
    }

    private fun launchApp(id: Int) {
        try {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .setAction(RideNotification.ACTION_ACTIVITY)
                    .putExtra(RideNotification.EXTRA_ACTION, RideNotification.MAP)
                    .putExtra(RideNotification.EXTRA_TOKEN, RideNotification.processToken)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            )
        } catch (e: Exception) {
            // App not openable right now: the alert stays in the notification shade.
        }
        silence(id)
        finish()
    }

    private fun close(id: Int) {
        silence(id)
        finish()
    }

    /** The rider has seen it: stop the insistent sound (the alert stays in the app). */
    private fun silence(id: Int) {
        if (id == 0) return
        try {
            getSystemService(NotificationManager::class.java)?.cancel(id)
        } catch (e: Exception) {
            // already gone
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
}
