package space.devmonks.coroute_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * Lock-Screen Compliant First Responder ICE (In Case of Emergency) Card.
 *
 * Displays critical medical identity, blood group, allergies, conditions, and 1-tap
 * emergency calling buttons for next-of-kin and 112 over the lock screen without
 * requiring the bystander or paramedic to enter the phone PIN or biometric unlock.
 */
class MedicalIdActivity : Activity() {

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Show over lock screen and turn screen on
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Read preferences stored by Flutter
        val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val userName = prefs.getString("flutter.medical_user_name", "")?.ifEmpty { "Motorcycle Rider" } ?: "Motorcycle Rider"
        val bloodGroup = prefs.getString("flutter.medical_blood_group", "")?.ifEmpty { "Not Specified" } ?: "Not Specified"
        val allergies = prefs.getString("flutter.medical_allergies", "")?.ifEmpty { "No known drug allergies reported" } ?: "No known drug allergies reported"
        val notes = prefs.getString("flutter.medical_notes", "")?.ifEmpty { "No chronic conditions reported" } ?: "No chronic conditions reported"
        val contactName = prefs.getString("flutter.medical_contact_name", "")?.ifEmpty { "Emergency Contact" } ?: "Emergency Contact"
        val contactPhone = prefs.getString("flutter.medical_contact_phone", "")?.ifEmpty { "" } ?: ""

        val root = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor("#0F1115"))
            isFillViewport = true
        }

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(24))
        }
        root.addView(container)

        // 1. Header Banner
        val header = TextView(this).apply {
            text = "FIRST RESPONDER / ICE CARD"
            setTextColor(Color.parseColor("#FF5252"))
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            letterSpacing = 0.15f
            setPadding(0, 0, 0, dp(6))
        }
        container.addView(header)

        // 2. Rider Name
        val nameView = TextView(this).apply {
            text = userName
            setTextColor(Color.WHITE)
            textSize = 24f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, 0, 0, dp(16))
        }
        container.addView(nameView)

        // 3. Blood Group Badge Card
        val bloodCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val bg = GradientDrawable().apply {
                setColor(Color.parseColor("#260808"))
                cornerRadius = dp(12).toFloat()
                setStroke(dp(2), Color.parseColor("#E53935"))
            }
            background = bg
            setPadding(dp(16), dp(14), dp(16), dp(14))
        }

        val bloodLabel = TextView(this).apply {
            text = "BLOOD GROUP"
            setTextColor(Color.parseColor("#EF9A9A"))
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            letterSpacing = 0.1f
        }
        val bloodVal = TextView(this).apply {
            text = bloodGroup
            setTextColor(Color.WHITE)
            textSize = 28f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(4), 0, 0)
        }
        bloodCard.addView(bloodLabel)
        bloodCard.addView(bloodVal)
        container.addView(bloodCard)

        container.addView(space(12))

        // 4. Allergies Card
        container.addView(createSectionCard("ALLERGIES & CONTRAINDICATIONS", allergies, "#FFA726", "#201608"))

        container.addView(space(12))

        // 5. Medical Conditions / Notes Card
        container.addView(createSectionCard("MEDICAL CONDITIONS & NOTES", notes, "#42A5F5", "#0A1929"))

        container.addView(space(20))

        // 6. Action: 1-Tap Dial Next-Of-Kin
        if (contactPhone.isNotEmpty()) {
            val callContactBtn = Button(this).apply {
                text = "CALL ICE CONTACT ($contactName)"
                setTextColor(Color.WHITE)
                textSize = 14f
                typeface = Typeface.DEFAULT_BOLD
                val btnBg = GradientDrawable().apply {
                    setColor(Color.parseColor("#1B5E20")) // dark green
                    cornerRadius = dp(10).toFloat()
                }
                background = btnBg
                setPadding(dp(16), dp(16), dp(16), dp(16))
                setOnClickListener {
                    try {
                        val dialIntent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$contactPhone")).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(dialIntent)
                    } catch (_: Exception) {}
                }
            }
            container.addView(callContactBtn)
            container.addView(space(10))
        }

        // 7. Action: 1-Tap Dial 112
        val call112Btn = Button(this).apply {
            text = "CALL 112 NATIONAL EMERGENCY"
            setTextColor(Color.WHITE)
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            val btnBg = GradientDrawable().apply {
                setColor(Color.parseColor("#B71C1C")) // dark red
                cornerRadius = dp(10).toFloat()
            }
            background = btnBg
            setPadding(dp(16), dp(16), dp(16), dp(16))
            setOnClickListener {
                try {
                    val dialIntent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:112")).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(dialIntent)
                } catch (_: Exception) {}
            }
        }
        container.addView(call112Btn)

        container.addView(space(16))

        // 8. Close Button
        val closeBtn = Button(this).apply {
            text = "CLOSE"
            setTextColor(Color.parseColor("#9E9E9E"))
            textSize = 13f
            val btnBg = GradientDrawable().apply {
                setColor(Color.parseColor("#1E222B"))
                cornerRadius = dp(10).toFloat()
            }
            background = btnBg
            setPadding(dp(16), dp(12), dp(16), dp(12))
            setOnClickListener { finish() }
        }
        container.addView(closeBtn)

        setContentView(root)
    }

    private fun createSectionCard(title: String, body: String, accentHex: String, bgHex: String): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val bg = GradientDrawable().apply {
                setColor(Color.parseColor(bgHex))
                cornerRadius = dp(12).toFloat()
                setStroke(dp(1), Color.parseColor(accentHex))
            }
            background = bg
            setPadding(dp(16), dp(14), dp(16), dp(14))
        }

        val label = TextView(this).apply {
            text = title
            setTextColor(Color.parseColor(accentHex))
            textSize = 11f
            typeface = Typeface.DEFAULT_BOLD
            letterSpacing = 0.08f
        }
        val text = TextView(this).apply {
            this.text = body
            setTextColor(Color.parseColor("#E0E0E0"))
            textSize = 15f
            setPadding(0, dp(4), 0, 0)
        }
        card.addView(label)
        card.addView(text)
        return card
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun space(heightDp: Int): View = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(heightDp))
    }
}
