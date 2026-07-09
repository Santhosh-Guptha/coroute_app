package com.example.travelsafetyapp.ui.screen

import android.widget.Toast
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.travelsafetyapp.domain.model.TripHistory
import com.example.travelsafetyapp.ui.viewmodel.GroupViewModel
import com.example.travelsafetyapp.ui.component.LocationAutoCompleteTextField

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JoinCreateScreen(
    viewModel: GroupViewModel,
    onNavigateToDashboard: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val isGmailVerified by viewModel.isGmailVerified.collectAsState()
    val verifiedEmail by viewModel.verifiedEmail.collectAsState()
    val activeGroup by viewModel.activeGroup.collectAsState()
    val errorState by viewModel.errorState.collectAsState()
    val tripHistory by viewModel.tripHistory.collectAsState()
    val memberLocations by viewModel.memberLocations.collectAsState()
    val isProfileCompleted by viewModel.isProfileCompleted.collectAsState()

    val isDark by viewModel.isDarkTheme.collectAsState()
    val themeModeVal by viewModel.themeMode.collectAsState()

    val bgGradientColors = if (isDark) listOf(Color(0xFF1E1B4B), Color(0xFF0F172A)) else listOf(Color(0xFFEEF2F6), Color(0xFFDDE3EA))
    val cardColor = if (isDark) Color(0xFF1E293B) else Color.White
    val textPrimary = if (isDark) Color.White else Color(0xFF0F172A)
    val textSecondary = if (isDark) Color(0xFF94A3B8) else Color(0xFF475569)
    val dividerColor = if (isDark) Color(0xFF334155) else Color(0xFFE2E8F0)

    // Home menu selection: null = main menu, "create", "join", "history"
    var selectedMenu by remember { mutableStateOf<String?>(null) }
    var showProfileDialogHome by remember { mutableStateOf(false) }

    var profileType by remember { mutableStateOf("") }
    var profileNo by remember { mutableStateOf("") }
    var profileColor by remember { mutableStateOf("") }
    var profileContact by remember { mutableStateOf("") }
    var profileCoRiding by remember { mutableStateOf(false) }

    // Screen input states
    var userName by remember { mutableStateOf(viewModel.getSavedDisplayName() ?: "") }
    var groupName by remember { mutableStateOf("") }
    var joinCode by remember { mutableStateOf("") }

    // Routing parameters
    var startPoint by remember { mutableStateOf("") }
    var destination by remember { mutableStateOf("") }
    var nextStopPoint by remember { mutableStateOf("") }

    // OTP verification inputs
    var emailInput by remember { mutableStateOf("") }
    var otpInput by remember { mutableStateOf("") }
    var isOtpSent by remember { mutableStateOf(false) }
    var isSendingOtp by remember { mutableStateOf(false) }

    // Consume deep link groupId if present
    val deepLinkCode = com.example.travelsafetyapp.MainActivity.deepLinkGroupId.value
    LaunchedEffect(deepLinkCode) {
        if (!deepLinkCode.isNullOrBlank()) {
            selectedMenu = "join"
            joinCode = deepLinkCode
            com.example.travelsafetyapp.MainActivity.deepLinkGroupId.value = null
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    colors = bgGradientColors
                )
            )
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp)
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Top
        ) {
            // Header / App Logo
            Spacer(modifier = Modifier.height(16.dp))
            Icon(
                imageVector = Icons.Default.ShareLocation,
                contentDescription = "App Logo",
                tint = Color(0xFF818CF8),
                modifier = Modifier
                    .size(56.dp)
                    .padding(bottom = 8.dp)
            )
            Text(
                text = "CoRoute",
                color = textPrimary,
                fontWeight = FontWeight.ExtraBold,
                fontSize = 28.sp
            )
            Text(
                text = "Live Group Safety Tracking",
                color = textSecondary,
                fontSize = 14.sp,
                modifier = Modifier.padding(bottom = 24.dp)
            )

            if (!isGmailVerified) {
                // ─── Email Verification Card ───
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(containerColor = cardColor.copy(alpha = 0.9f)),
                    elevation = CardDefaults.cardElevation(defaultElevation = 8.dp)
                ) {
                    Column(
                        modifier = Modifier.padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Text("Mandatory Email Verification", color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                        Text(
                            text = "To access the safety tracking system, verify your Gmail address with a secure OTP.",
                            color = textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center
                        )

                        if (!isOtpSent) {
                            OutlinedTextField(
                                value = emailInput,
                                onValueChange = { emailInput = it },
                                label = { Text("Gmail Address", color = textSecondary) },
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = Color(0xFF818CF8), unfocusedBorderColor = dividerColor,
                                    focusedTextColor = textPrimary, unfocusedTextColor = textPrimary
                                ),
                                singleLine = true, modifier = Modifier.fillMaxWidth()
                            )

                            Button(
                                onClick = {
                                    if (emailInput.isNotBlank()) {
                                        isSendingOtp = true
                                        viewModel.sendOtpVerification(emailInput) { res ->
                                            isSendingOtp = false
                                            res.fold(
                                                onSuccess = { isOtpSent = true; Toast.makeText(context, "Verification OTP email sent!", Toast.LENGTH_SHORT).show() },
                                                onFailure = { err -> Toast.makeText(context, "Failed to send OTP: ${err.localizedMessage}", Toast.LENGTH_LONG).show() }
                                            )
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6366F1)),
                                enabled = emailInput.isNotBlank() && !isSendingOtp
                            ) {
                                if (isSendingOtp) CircularProgressIndicator(color = Color.White, modifier = Modifier.size(24.dp))
                                else Text("Send Verification OTP")
                            }
                        } else {
                            Text("OTP Sent to $emailInput", color = Color(0xFF34D399), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                            OutlinedTextField(
                                value = otpInput, onValueChange = { otpInput = it },
                                label = { Text("Enter 6-Digit OTP", color = textSecondary) },
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = Color(0xFF818CF8), unfocusedBorderColor = dividerColor,
                                    focusedTextColor = textPrimary, unfocusedTextColor = textPrimary
                                ),
                                singleLine = true, modifier = Modifier.fillMaxWidth()
                            )
                            Button(
                                onClick = {
                                    if (viewModel.verifyOtp(otpInput)) {
                                        viewModel.setGmailVerified(emailInput)
                                        Toast.makeText(context, "Gmail verified successfully!", Toast.LENGTH_SHORT).show()
                                    } else {
                                        Toast.makeText(context, "Invalid OTP code. Please check your mail.", Toast.LENGTH_SHORT).show()
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF10B981)),
                                enabled = otpInput.length >= 4
                            ) { Text("Verify & Login") }

                            TextButton(onClick = { isOtpSent = false }) {
                                Text("Resend / Try Another Email", color = textSecondary)
                            }
                        }
                    }
                }
            } else {
                // ─── Verified Home Page ───

                // User status bar
                Row(
                    modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Default.Verified, contentDescription = "Verified", tint = Color(0xFF34D399), modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(text = "Logged in as: $verifiedEmail", color = textSecondary, fontSize = 12.sp)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Edit Profile",
                        color = Color(0xFF818CF8),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.clickable { showProfileDialogHome = true }
                    )
                }

                // Active trip banner
                activeGroup?.let { group ->
                    Card(
                        modifier = Modifier.fillMaxWidth().padding(bottom = 20.dp),
                        shape = RoundedCornerShape(12.dp),
                        colors = CardDefaults.cardColors(containerColor = cardColor.copy(alpha = 0.9f))
                    ) {
                        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Column {
                                    Text("ACTIVE TRIP", color = Color(0xFF34D399), fontSize = 11.sp, fontWeight = FontWeight.Bold)
                                    Text(text = group.name, color = textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                                    Text("PIN: ${group.groupId}", color = Color(0xFF818CF8), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                                }
                                Button(
                                    onClick = onNavigateToDashboard,
                                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6366F1))
                                ) {
                                    Icon(Icons.Default.Map, contentDescription = "View Map", modifier = Modifier.size(16.dp))
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text("View Map")
                                }
                            }
                            HorizontalDivider(color = dividerColor)

                             Surface(
                                 color = Color(0xFF10B981).copy(alpha = 0.15f),
                                 shape = RoundedCornerShape(8.dp),
                                 modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)
                             ) {
                                 Row(
                                     modifier = Modifier.padding(12.dp),
                                     verticalAlignment = Alignment.CenterVertically
                                 ) {
                                     Icon(Icons.Default.Shield, contentDescription = null, tint = Color(0xFF10B981))
                                     Spacer(modifier = Modifier.width(12.dp))
                                     Text(
                                         text = "Real-time background safety tracking & messaging are active.",
                                         color = Color(0xFF10B981),
                                         fontSize = 13.sp,
                                         fontWeight = FontWeight.Medium
                                     )
                                 }
                             }

                            HorizontalDivider(color = dividerColor)
                            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Start", color = textSecondary, fontSize = 12.sp)
                                    Text(group.startPoint.ifBlank { "—" }, color = textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                                }
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Destination", color = textSecondary, fontSize = 12.sp)
                                    Text(group.destination.ifBlank { "—" }, color = textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                    }
                }

                // ─── Main Menu or Sub-screen ───
                AnimatedContent(targetState = selectedMenu, label = "menu_transition") { menu ->
                    when (menu) {
                        null -> {
                            // Main Menu Cards
                            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                if (!isProfileCompleted) {
                                    Card(
                                        modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                                        shape = RoundedCornerShape(12.dp),
                                        colors = CardDefaults.cardColors(containerColor = Color(0xFFEF4444).copy(alpha = 0.15f)),
                                        border = BorderStroke(1.dp, Color(0xFFEF4444).copy(alpha = 0.5f))
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(16.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Icon(Icons.Default.Warning, contentDescription = null, tint = Color(0xFFEF4444), modifier = Modifier.size(24.dp))
                                            Spacer(modifier = Modifier.width(12.dp))
                                            Column(modifier = Modifier.weight(1f)) {
                                                Text("Profile Incomplete", color = Color(0xFFEF4444), fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                                Text("Mandatory vehicle registration is required before starting or joining trips.", color = textSecondary, fontSize = 12.sp)
                                            }
                                            Button(
                                                onClick = { showProfileDialogHome = true },
                                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444))
                                            ) {
                                                Text("Register", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                                            }
                                        }
                                    }
                                }

                                HomeMenuCard(
                                    icon = Icons.Default.AddCircle,
                                    title = "Create Trip",
                                    subtitle = "Start a new tracking group with a customized name",
                                    color = Color(0xFF6366F1),
                                    cardColor = cardColor,
                                    textPrimary = textPrimary,
                                    textSecondary = textSecondary,
                                    isEnabled = isProfileCompleted,
                                    onClick = { 
                                        if (!isProfileCompleted) {
                                            showProfileDialogHome = true
                                            Toast.makeText(context, "Please complete your mandatory safety profile first!", Toast.LENGTH_LONG).show()
                                        } else if (activeGroup != null) {
                                            Toast.makeText(context, "You are already in an active trip! Please leave or end the current trip first.", Toast.LENGTH_LONG).show()
                                        } else {
                                            selectedMenu = "create"
                                        }
                                    }
                                )
                                HomeMenuCard(
                                    icon = Icons.Default.GroupAdd,
                                    title = "Join Trip",
                                    subtitle = "Enter a 6-digit PIN to join an existing group",
                                    color = Color(0xFF10B981),
                                    cardColor = cardColor,
                                    textPrimary = textPrimary,
                                    textSecondary = textSecondary,
                                    isEnabled = isProfileCompleted,
                                    onClick = { 
                                        if (!isProfileCompleted) {
                                            showProfileDialogHome = true
                                            Toast.makeText(context, "Please complete your mandatory safety profile first!", Toast.LENGTH_LONG).show()
                                        } else if (activeGroup != null) {
                                            Toast.makeText(context, "You are already in an active trip! Please leave or end the current trip first.", Toast.LENGTH_LONG).show()
                                        } else {
                                            selectedMenu = "join"
                                        }
                                    }
                                )
                                HomeMenuCard(
                                    icon = Icons.Default.History,
                                    title = "Trip History",
                                    subtitle = "${tripHistory.size} past trips recorded",
                                    color = Color(0xFFF59E0B),
                                    cardColor = cardColor,
                                    textPrimary = textPrimary,
                                    textSecondary = textSecondary,
                                    onClick = { selectedMenu = "history" }
                                )
                            }
                        }
                        "create" -> {
                            // Create Trip Form
                            CreateTripForm(
                                groupName = groupName, onGroupNameChange = { groupName = it },
                                startPoint = startPoint, onStartPointChange = { startPoint = it },
                                destination = destination, onDestinationChange = { destination = it },
                                nextStopPoint = nextStopPoint, onNextStopChange = { nextStopPoint = it },
                                errorState = errorState,
                                cardColor = cardColor,
                                textPrimary = textPrimary,
                                textSecondary = textSecondary,
                                dividerColor = dividerColor,
                                onBack = { selectedMenu = null },
                                onCreateTrip = {
                                    val finalName = userName.ifBlank { viewModel.getSavedDisplayName() ?: "User" }
                                    viewModel.createGroup(groupName, finalName, startPoint, destination, nextStopPoint) {
                                        onNavigateToDashboard()
                                    }
                                }
                            )
                        }
                        "join" -> {
                            // Join Trip Form
                            JoinTripForm(
                                joinCode = joinCode, onJoinCodeChange = { joinCode = it },
                                errorState = errorState,
                                cardColor = cardColor,
                                textPrimary = textPrimary,
                                textSecondary = textSecondary,
                                dividerColor = dividerColor,
                                onBack = { selectedMenu = null },
                                onJoinTrip = {
                                    val finalName = userName.ifBlank { viewModel.getSavedDisplayName() ?: "User" }
                                    viewModel.joinGroup(joinCode, finalName) { onNavigateToDashboard() }
                                }
                            )
                        }
                        "history" -> {
                            // Trip History List
                            TripHistoryScreen(
                                history = tripHistory,
                                cardColor = cardColor,
                                textPrimary = textPrimary,
                                textSecondary = textSecondary,
                                onBack = { selectedMenu = null }
                            )
                        }
                    }
                }
            }

        }

        IconButton(
            onClick = {
                val nextMode = when (themeModeVal) {
                    "Time" -> "Light"
                    "Light" -> "Dark"
                    else -> "Time"
                }
                viewModel.setThemeMode(nextMode)
            },
            modifier = Modifier.align(Alignment.TopEnd).padding(16.dp)
        ) {
            Icon(
                imageVector = when (themeModeVal) {
                    "Light" -> Icons.Default.WbSunny
                    "Dark" -> Icons.Default.DarkMode
                    else -> Icons.Default.Schedule
                },
                contentDescription = "Change Theme",
                tint = textPrimary,
                modifier = Modifier.size(24.dp)
            )
        }
    }

    LaunchedEffect(showProfileDialogHome) {
        if (showProfileDialogHome) {
            val myLoc = memberLocations[viewModel.currentUserId]
            profileType = myLoc?.vehicleType ?: ""
            profileNo = myLoc?.vehicleNo ?: ""
            profileColor = myLoc?.vehicleColor ?: ""
            profileContact = myLoc?.emergencyContact ?: ""
            profileCoRiding = myLoc?.isCoRiding ?: false
        }
    }

    if (showProfileDialogHome) {
        AlertDialog(
            onDismissRequest = { if (isProfileCompleted) showProfileDialogHome = false },
            title = { Text("Safety Profile Registration", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(
                    modifier = Modifier.verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(
                        text = "To ensure group tracking, specify your vehicle or pillion details. All fields are mandatory.",
                        color = textSecondary,
                        fontSize = 13.sp
                    )

                    OutlinedTextField(
                        value = userName,
                        onValueChange = { userName = it },
                        label = { Text("Your Display Name", color = textSecondary) },
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = Color(0xFF818CF8),
                            unfocusedBorderColor = dividerColor,
                            focusedTextColor = textPrimary,
                            unfocusedTextColor = textPrimary
                        ),
                        singleLine = true
                    )

                    // Co-riding Switch toggle card
                    Surface(
                        color = dividerColor.copy(alpha = 0.5f),
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            modifier = Modifier.padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Co-Riding (Pillion)", color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                Text("Riding with another rider", color = textSecondary, fontSize = 11.sp)
                            }
                            Switch(
                                checked = profileCoRiding,
                                onCheckedChange = { profileCoRiding = it },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = Color(0xFF818CF8),
                                    checkedTrackColor = Color(0xFF312E81)
                                )
                            )
                        }
                    }

                    if (!profileCoRiding) {
                        OutlinedTextField(
                            value = profileType,
                            onValueChange = { profileType = it },
                            label = { Text("Vehicle Type (e.g. KTM 390)", color = textSecondary) },
                            modifier = Modifier.fillMaxWidth(),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = Color(0xFF818CF8),
                                unfocusedBorderColor = dividerColor,
                                focusedTextColor = textPrimary,
                                unfocusedTextColor = textPrimary
                            ),
                            singleLine = true
                        )
                        OutlinedTextField(
                            value = profileNo,
                            onValueChange = { profileNo = it },
                            label = { Text("Vehicle Number", color = textSecondary) },
                            modifier = Modifier.fillMaxWidth(),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = Color(0xFF818CF8),
                                unfocusedBorderColor = dividerColor,
                                focusedTextColor = textPrimary,
                                unfocusedTextColor = textPrimary
                            ),
                            singleLine = true
                        )
                        OutlinedTextField(
                            value = profileColor,
                            onValueChange = { profileColor = it },
                            label = { Text("Vehicle Color", color = textSecondary) },
                            modifier = Modifier.fillMaxWidth(),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = Color(0xFF818CF8),
                                unfocusedBorderColor = dividerColor,
                                focusedTextColor = textPrimary,
                                unfocusedTextColor = textPrimary
                            ),
                            singleLine = true
                        )
                    }

                    OutlinedTextField(
                        value = profileContact,
                        onValueChange = { profileContact = it },
                        label = { Text("Emergency Contact Number", color = textSecondary) },
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = Color(0xFF818CF8),
                            unfocusedBorderColor = dividerColor,
                            focusedTextColor = textPrimary,
                            unfocusedTextColor = textPrimary
                        ),
                        singleLine = true
                    )

                    HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = 4.dp))
                    Text(
                        text = "Theme Settings",
                        color = textPrimary,
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        val modes = listOf("Time" to "Auto", "Light" to "Light", "Dark" to "Dark")
                        modes.forEach { (modeVal, label) ->
                            FilterChip(
                                selected = themeModeVal == modeVal,
                                onClick = { viewModel.setThemeMode(modeVal) },
                                label = { Text(label, fontSize = 11.sp, fontWeight = FontWeight.Bold) },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = Color(0xFF818CF8).copy(alpha = 0.3f),
                                    selectedLabelColor = Color(0xFF818CF8),
                                    containerColor = dividerColor.copy(alpha = 0.3f),
                                    labelColor = textSecondary
                                ),
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                }
            },
            confirmButton = {
                val isValid = userName.isNotBlank() && if (profileCoRiding) {
                    profileContact.isNotBlank()
                } else {
                    profileType.isNotBlank() && profileNo.isNotBlank() && profileColor.isNotBlank() && profileContact.isNotBlank()
                }
                
                Button(
                    onClick = {
                        if (isValid) {
                            val trimmedName = userName.trim()
                            viewModel.saveUserDisplayName(trimmedName)
                            userName = trimmedName
                            viewModel.updateVehicleProfile(
                                vehicleType = if (profileCoRiding) "Pillion Rider" else profileType.trim(),
                                vehicleNo = if (profileCoRiding) "Co-Rider" else profileNo.trim(),
                                vehicleColor = if (profileCoRiding) "N/A" else profileColor.trim(),
                                emergencyContact = profileContact.trim(),
                                isCoRiding = profileCoRiding,
                                ridingWithUserId = "",
                                ridingWithUserName = ""
                            ) { success ->
                                if (success) {
                                    showProfileDialogHome = false
                                    Toast.makeText(context, "Safety profile saved successfully!", Toast.LENGTH_SHORT).show()
                                } else {
                                    Toast.makeText(context, "Failed to save safety profile.", Toast.LENGTH_LONG).show()
                                }
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6366F1)),
                    enabled = isValid
                ) {
                    Text("Save & Complete")
                }
            },
            dismissButton = {
                if (isProfileCompleted) {
                    TextButton(onClick = { showProfileDialogHome = false }) {
                        Text("Cancel", color = textSecondary)
                    }
                }
            },
            containerColor = cardColor
        )
    }
}

// ─── Home Menu Card ───
@Composable
fun HomeMenuCard(
    icon: ImageVector,
    title: String,
    subtitle: String,
    color: Color,
    cardColor: Color,
    textPrimary: Color,
    textSecondary: Color,
    isEnabled: Boolean = true,
    onClick: () -> Unit
) {
    val alpha = if (isEnabled) 1.0f else 0.5f
    Card(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).clickable { onClick() },
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = cardColor.copy(alpha = 0.85f * alpha)),
        elevation = CardDefaults.cardElevation(defaultElevation = 6.dp)
    ) {
        Row(
            modifier = Modifier.padding(20.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(52.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(color.copy(alpha = 0.15f * alpha)),
                contentAlignment = Alignment.Center
            ) {
                Icon(icon, contentDescription = title, tint = color.copy(alpha = alpha), modifier = Modifier.size(28.dp))
            }
            Spacer(modifier = Modifier.width(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, color = textPrimary.copy(alpha = alpha), fontWeight = FontWeight.Bold, fontSize = 17.sp)
                Text(subtitle, color = textSecondary.copy(alpha = alpha), fontSize = 13.sp)
            }
            Icon(
                imageVector = if (isEnabled) Icons.Default.ChevronRight else Icons.Default.Lock,
                contentDescription = null,
                tint = textSecondary.copy(alpha = alpha)
            )
        }
    }
}

// ─── Create Trip Form ───
@Composable
fun CreateTripForm(
    groupName: String, onGroupNameChange: (String) -> Unit,
    startPoint: String, onStartPointChange: (String) -> Unit,
    destination: String, onDestinationChange: (String) -> Unit,
    nextStopPoint: String, onNextStopChange: (String) -> Unit,
    errorState: String?,
    cardColor: Color,
    textPrimary: Color,
    textSecondary: Color,
    dividerColor: Color,
    onBack: () -> Unit,
    onCreateTrip: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = cardColor.copy(alpha = 0.85f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 8.dp)
    ) {
        Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = textSecondary)
                }
                Text("Create New Trip", color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 20.sp)
            }

            OutlinedTextField(
                value = groupName, onValueChange = onGroupNameChange,
                label = { Text("Trip Name (e.g. Goa Road Trip)", color = textSecondary) },
                leadingIcon = { Icon(Icons.Default.DriveFileRenameOutline, contentDescription = null, tint = Color(0xFF818CF8)) },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color(0xFF818CF8), unfocusedBorderColor = dividerColor,
                    focusedTextColor = textPrimary, unfocusedTextColor = textPrimary
                ),
                singleLine = true, modifier = Modifier.fillMaxWidth()
            )

            HorizontalDivider(color = dividerColor)
            Text("ROUTE DETAILS", color = Color(0xFF818CF8), fontSize = 11.sp, fontWeight = FontWeight.Bold)

            LocationAutoCompleteTextField(
                value = startPoint,
                onValueChange = onStartPointChange,
                label = "Start Location",
                leadingIcon = { Icon(Icons.Default.TripOrigin, contentDescription = null, tint = Color(0xFF10B981)) },
                textPrimary = textPrimary,
                textSecondary = textSecondary,
                cardColor = cardColor,
                dividerColor = dividerColor,
                modifier = Modifier.fillMaxWidth()
            )
            LocationAutoCompleteTextField(
                value = destination,
                onValueChange = onDestinationChange,
                label = "Destination",
                leadingIcon = { Icon(Icons.Default.Flag, contentDescription = null, tint = Color(0xFFEF4444)) },
                textPrimary = textPrimary,
                textSecondary = textSecondary,
                cardColor = cardColor,
                dividerColor = dividerColor,
                modifier = Modifier.fillMaxWidth()
            )
            LocationAutoCompleteTextField(
                value = nextStopPoint,
                onValueChange = onNextStopChange,
                label = "First Stop Point (Optional)",
                leadingIcon = { Icon(Icons.Default.PinDrop, contentDescription = null, tint = Color(0xFFFBBF24)) },
                textPrimary = textPrimary,
                textSecondary = textSecondary,
                cardColor = cardColor,
                dividerColor = dividerColor,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(8.dp))

            Button(
                onClick = onCreateTrip,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6366F1)),
                shape = RoundedCornerShape(10.dp),
                enabled = groupName.isNotBlank() && startPoint.isNotBlank() && destination.isNotBlank()
            ) {
                Icon(Icons.Default.RocketLaunch, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(modifier = Modifier.width(8.dp))
                Text("Create & Start Trip", fontSize = 16.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 4.dp))
            }

            errorState?.let { err ->
                Text(text = err, color = Color(0xFFF87171), fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

// ─── Join Trip Form ───
@Composable
fun JoinTripForm(
    joinCode: String, onJoinCodeChange: (String) -> Unit,
    errorState: String?,
    cardColor: Color,
    textPrimary: Color,
    textSecondary: Color,
    dividerColor: Color,
    onBack: () -> Unit,
    onJoinTrip: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = cardColor.copy(alpha = 0.85f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 8.dp)
    ) {
        Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = textSecondary)
                }
                Text("Join Existing Trip", color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 20.sp)
            }

            OutlinedTextField(
                value = joinCode, onValueChange = onJoinCodeChange,
                label = { Text("Enter 6-Digit Group PIN", color = textSecondary) },
                leadingIcon = { Icon(Icons.Default.Pin, contentDescription = null, tint = Color(0xFF10B981)) },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color(0xFF10B981), unfocusedBorderColor = dividerColor,
                    focusedTextColor = textPrimary, unfocusedTextColor = textPrimary
                ),
                singleLine = true, modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(8.dp))

            Button(
                onClick = onJoinTrip,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF10B981)),
                shape = RoundedCornerShape(10.dp),
                enabled = joinCode.isNotBlank()
            ) {
                Icon(Icons.Default.GroupAdd, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(modifier = Modifier.width(8.dp))
                Text("Join Live Group", fontSize = 16.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 4.dp))
            }

            errorState?.let { err ->
                Text(text = err, color = Color(0xFFF87171), fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

// ─── Trip History Screen ───
@Composable
fun TripHistoryScreen(
    history: List<TripHistory>,
    cardColor: Color,
    textPrimary: Color,
    textSecondary: Color,
    onBack: () -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = textSecondary)
            }
            Text("Trip History", color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 20.sp)
        }

        if (history.isEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = cardColor.copy(alpha = 0.85f))
            ) {
                Column(
                    modifier = Modifier.padding(32.dp).fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(Icons.Default.Explore, contentDescription = null, tint = textSecondary, modifier = Modifier.size(48.dp))
                    Text("No trips yet", color = textSecondary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text("Your completed trips will appear here.", color = textSecondary.copy(alpha = 0.7f), fontSize = 13.sp, textAlign = TextAlign.Center)
                }
            }
        } else {
            history.forEach { trip ->
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = CardDefaults.cardColors(containerColor = cardColor.copy(alpha = 0.85f))
                ) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(trip.tripName, color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                            Text(
                                text = "PIN: ${trip.groupId}",
                                color = Color(0xFF818CF8),
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.TripOrigin, contentDescription = null, tint = Color(0xFF10B981), modifier = Modifier.size(14.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                Text(trip.startPoint.ifBlank { "—" }, color = textSecondary, fontSize = 13.sp)
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Flag, contentDescription = null, tint = Color(0xFFEF4444), modifier = Modifier.size(14.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                Text(trip.destination.ifBlank { "—" }, color = textSecondary, fontSize = 13.sp)
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.People, contentDescription = null, tint = textSecondary, modifier = Modifier.size(14.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("${trip.memberCount} members", color = textSecondary, fontSize = 12.sp)
                            }
                            if (trip.endedAt > 0) {
                                val dateStr = java.text.SimpleDateFormat("dd MMM yyyy, hh:mm a", java.util.Locale.getDefault()).format(java.util.Date(trip.endedAt))
                                Text(dateStr, color = textSecondary, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}
