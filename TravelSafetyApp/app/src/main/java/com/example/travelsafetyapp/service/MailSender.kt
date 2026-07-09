package com.example.travelsafetyapp.service

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Properties
import javax.mail.Authenticator
import javax.mail.Message
import javax.mail.PasswordAuthentication
import javax.mail.Session
import javax.mail.Transport
import javax.mail.internet.InternetAddress
import javax.mail.internet.MimeMessage

object MailSender {
    // Default SMTP configurations
    const val smtpHost = "smtp.gmail.com"
    const val smtpPort = "587"
    const val smtpUsername = "santhoshbukka5@gmail.com"
    const val smtpPassword = "nqkq huov lhiv tdan"

    suspend fun sendOtpEmail(
        recipientEmail: String,
        otpCode: String
    ): Result<Boolean> = withContext(Dispatchers.IO) {
        if (smtpUsername.isBlank() || smtpPassword.isBlank()) {
            return@withContext Result.failure(Exception("SMTP configuration is incomplete. Add username and App Password."))
        }

        try {
            val props = Properties().apply {
                put("mail.smtp.auth", "true")
                put("mail.smtp.starttls.enable", "true")
                put("mail.smtp.host", smtpHost)
                put("mail.smtp.port", smtpPort)
            }

            val session = Session.getInstance(props, object : Authenticator() {
                override fun getPasswordAuthentication(): PasswordAuthentication {
                    return PasswordAuthentication(smtpUsername, smtpPassword)
                }
            })

            val message = MimeMessage(session).apply {
                setFrom(InternetAddress(smtpUsername))
                setRecipients(Message.RecipientType.TO, InternetAddress.parse(recipientEmail))
                subject = "CoRoute Security OTP Verification"
                
                setText(
                    """
                    Hi,
                    
                    Your CoRoute security verification OTP is:
                    
                    $otpCode
                    
                    Please enter this code in the application to complete verification and access the safety tracking system.
                    
                    Do not share this OTP with anyone.
                    
                    CoRoute Travel Safety Team
                    """.trimIndent()
                )
            }

            Transport.send(message)
            Result.success(true)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
