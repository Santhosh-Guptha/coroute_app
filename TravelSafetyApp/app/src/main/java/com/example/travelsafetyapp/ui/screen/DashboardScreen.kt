package com.example.travelsafetyapp.ui.screen

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.RingtoneManager
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.TabRowDefaults.tabIndicatorOffset
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.example.travelsafetyapp.ui.component.OpenStreetMap
import com.example.travelsafetyapp.service.TrackingService
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.travelsafetyapp.domain.model.GroupMessage
import com.example.travelsafetyapp.domain.model.MemberLocation
import com.example.travelsafetyapp.domain.model.SOSAlert
import com.example.travelsafetyapp.ui.viewmodel.GroupViewModel
import com.example.travelsafetyapp.ui.component.LocationAutoCompleteTextField
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(
    viewModel: GroupViewModel,
    onNavigateBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val activeGroup by viewModel.activeGroup.collectAsState()
    val memberLocations by viewModel.memberLocations.collectAsState()
    val myLoc = memberLocations[viewModel.currentUserId]
    val activeSOSAlerts by viewModel.activeSOSAlerts.collectAsState()
    val activeMessages by viewModel.activeMessages.collectAsState()
    val activeDistanceAlerts by viewModel.activeDistanceAlerts.collectAsState()
    val otherSOSAlerts = remember(activeSOSAlerts) {
        activeSOSAlerts.filter { alert ->
            val isFromSelf = alert.userId == viewModel.currentUserId
            val isTargetedToMe = alert.targetUserId == viewModel.currentUserId
            val isGlobal = alert.targetUserId.isBlank()
            !isFromSelf && (isGlobal || isTargetedToMe)
        }
    }
    val isServiceRunning by viewModel.isServiceRunning.collectAsState()
    val isSimulationMode by viewModel.isSimulationMode.collectAsState()
    val isGroupAdmin = activeGroup?.createdBy == viewModel.currentUserId

    val isDark by viewModel.isDarkTheme.collectAsState()
    val themeModeVal by viewModel.themeMode.collectAsState()

    val bgColor = if (isDark) Color(0xFF0F172A) else Color(0xFFF1F5F9)
    val cardColor = if (isDark) Color(0xFF1E293B) else Color.White
    val textPrimary = if (isDark) Color.White else Color(0xFF0F172A)
    val textSecondary = if (isDark) Color(0xFF94A3B8) else Color(0xFF475569)
    val dividerColor = if (isDark) Color(0xFF334155) else Color(0xFFE2E8F0)

    val selfCardColor = if (isDark) Color(0xFF1E3A5F) else Color(0xFFD0E1FD)
    val myBubbleColor = if (isDark) Color(0xFF312E81) else Color(0xFFDBEAFE)

    LaunchedEffect(Unit) {
        viewModel.startTrackingService()
    }

    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val coroutineScope = rememberCoroutineScope()
    var showLeaveConfirmation by remember { mutableStateOf(false) }
    var showSOSConfirmation by remember { mutableStateOf(false) }
    var showEndTripConfirmation by remember { mutableStateOf(false) }

    // Selected member details state
    var selectedMember by remember { mutableStateOf<MemberLocation?>(null) }
    var showRoleDialogForMember by remember { mutableStateOf<Pair<String, String>?>(null) }

    // Alarm states
    var activeTimerText by remember { mutableStateOf<String?>(null) }
    var activeTimerRequester by remember { mutableStateOf<String?>(null) }
    var showAlarmDialog by remember { mutableStateOf(false) }
    var currentPlayingRingtone by remember { mutableStateOf<android.media.Ringtone?>(null) }

    // Safety profile edit states
    var showProfileDialogDashboard by remember { mutableStateOf(false) }
    var profileName by remember { mutableStateOf("") }
    var profilePhone by remember { mutableStateOf("") }
    var profileType by remember { mutableStateOf("") }
    var profileNo by remember { mutableStateOf("") }
    var profileColor by remember { mutableStateOf("") }
    var profileModel by remember { mutableStateOf("") }
    var profileContact by remember { mutableStateOf("") }
    var profileContactName by remember { mutableStateOf("") }
    var profileCoRiding by remember { mutableStateOf(false) }

    LaunchedEffect(showProfileDialogDashboard) {
        if (showProfileDialogDashboard) {
            profileName = viewModel.getSavedDisplayName() ?: ""
            profilePhone = viewModel.getSavedPhone() ?: ""
            profileType = myLoc?.vehicleType ?: viewModel.getSavedVehicleType() ?: "Motorcycle"
            profileNo = myLoc?.vehicleNo ?: viewModel.getSavedVehicleNo() ?: ""
            profileColor = myLoc?.vehicleColor ?: viewModel.getSavedVehicleColor() ?: ""
            profileModel = myLoc?.vehicleModel ?: viewModel.getSavedVehicleModel() ?: ""
            profileContact = myLoc?.emergencyContact ?: viewModel.getSavedEmergencyContact() ?: ""
            profileContactName = myLoc?.emergencyContactName ?: viewModel.getSavedEmergencyContactName() ?: ""
            profileCoRiding = myLoc?.isCoRiding ?: viewModel.getSavedCoRiding()
        }
    }

    // Track wait requests to trigger 2-minute pull-over alarm based on timestamp
    LaunchedEffect(activeGroup?.waitRequests) {
        val currentRequests = activeGroup?.waitRequests ?: emptyMap()
        val now = System.currentTimeMillis()
        
        // Find the most recent active wait request that is within the 2-minute buffer
        val activeReq = currentRequests.values
            .filter { now - it.timestamp < 120_000L }
            .maxByOrNull { it.timestamp }
            
        if (activeReq != null) {
            val elapsedSecs = ((System.currentTimeMillis() - activeReq.timestamp) / 1000L).coerceAtLeast(0L)
            val remainingSecs = (120L - elapsedSecs).coerceAtLeast(0L)
            
            if (remainingSecs > 0) {
                activeTimerRequester = activeReq.userName
                
                // Run the countdown for the remaining seconds
                for (sec in remainingSecs downTo 0) {
                    val minsLeft = sec / 60
                    val secsLeft = sec % 60
                    activeTimerText = String.format("%02d:%02d", minsLeft, secsLeft)
                    delay(1000L)
                }
                activeTimerText = null
                
                // Trigger Alarm
                try {
                    val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    val rt = RingtoneManager.getRingtone(context, alarmUri)
                    currentPlayingRingtone = rt
                    rt.play()
                    showAlarmDialog = true
                } catch (e: Exception) { e.printStackTrace() }
            }
        } else {
            activeTimerText = null
            activeTimerRequester = null
        }
    }

    // Co-riding states
    var showCoRiderSelectionDialog by remember { mutableStateOf(false) }

    // Messaging states
    var showMessageDialog by remember { mutableStateOf(false) }
    var messageText by remember { mutableStateOf("") }
    var messagePriority by remember { mutableStateOf("Medium") }

    // Next stop states
    var showNextStopDialog by remember { mutableStateOf(false) }
    var nextStopInput by remember { mutableStateOf("") }

    // Tab selection
    var selectedTab by remember { mutableStateOf(0) } // 0=Riders, 1=Messages/Chat, 2=Stops

    // Quick Message template list (label to text + priority)
    val quickMessages = listOf(
        "⛽ Need Fuel" to ("Need Fuel" to "Medium"),
        "🛑 Road Block" to ("Road Block ahead!" to "Medium"),
        "💧 Water Break" to ("Need a water break" to "Medium"),
        "☕ Chai Break" to ("Stopping for Chai break" to "Medium"),
        "📍 Stopping Stop" to ("Stopping at next stop point" to "Medium"),
        "🚨 EMERGENCY!" to ("EMERGENCY! Need help immediately!" to "High")
    )

    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = bgColor,
        topBar = {
            Surface(
                color = cardColor,
                shadowElevation = 8.dp
            ) {
                Column(modifier = Modifier.statusBarsPadding()) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        // Non-destructive Back button - just navigate back to Home Screen
                        IconButton(onClick = onNavigateBack) {
                            Icon(Icons.Default.ArrowBack, "Back", tint = textPrimary)
                        }
                        Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                            Text(activeGroup?.name ?: "Trip Group", color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.clickable {
                                    activeGroup?.groupId?.let { code ->
                                        clipboardManager.setText(AnnotatedString(code))
                                        Toast.makeText(context, "Group code copied!", Toast.LENGTH_SHORT).show()
                                    }
                                }
                            ) {
                                Text("Code: ${activeGroup?.groupId ?: "..."}", color = Color(0xFF818CF8), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                                Spacer(modifier = Modifier.width(4.dp))
                                Icon(Icons.Default.ContentCopy, "Copy", tint = Color(0xFF818CF8), modifier = Modifier.size(11.dp))
                            }
                        }
                        
                        // Header actions (small buttons at the top)
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            val isPaused = myLoc?.isPaused == true
                            FilledTonalButton(
                                onClick = { viewModel.togglePauseTracking(!isPaused) },
                                colors = ButtonDefaults.filledTonalButtonColors(
                                    containerColor = if (isPaused) Color(0xFF10B981).copy(alpha = 0.2f) else Color(0xFFF59E0B).copy(alpha = 0.2f),
                                    contentColor = if (isPaused) Color(0xFF10B981) else Color(0xFFF59E0B)
                                ),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                                modifier = Modifier.height(32.dp)
                            ) {
                                Icon(
                                    imageVector = if (isPaused) Icons.Default.PlayArrow else Icons.Default.Pause,
                                    contentDescription = null,
                                    modifier = Modifier.size(14.dp)
                                )
                                Spacer(modifier = Modifier.width(4.dp))
                                Text(if (isPaused) "Resume" else "Pause", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            }

                            FilledTonalButton(
                                onClick = { showProfileDialogDashboard = true },
                                colors = ButtonDefaults.filledTonalButtonColors(
                                    containerColor = Color(0xFF6366F1).copy(alpha = 0.2f),
                                    contentColor = Color(0xFF818CF8)
                                ),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                                modifier = Modifier.height(32.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Default.TwoWheeler,
                                    contentDescription = null,
                                    modifier = Modifier.size(14.dp)
                                )
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("Vehicle", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            }

                            val isCreator = activeGroup?.createdBy == viewModel.currentUserId
                            FilledTonalButton(
                                onClick = { if (isCreator) showEndTripConfirmation = true else showLeaveConfirmation = true },
                                colors = ButtonDefaults.filledTonalButtonColors(
                                    containerColor = Color(0xFFEF4444).copy(alpha = 0.2f),
                                    contentColor = Color(0xFFEF4444)
                                ),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                                modifier = Modifier.height(32.dp)
                            ) {
                                Icon(
                                    imageVector = if (isCreator) Icons.Default.DeleteForever else Icons.Default.ExitToApp,
                                    contentDescription = null,
                                    modifier = Modifier.size(14.dp)
                                )
                                Spacer(modifier = Modifier.width(4.dp))
                                Text(if (isCreator) "End" else "Leave", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }

                    // Chips bar
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Surface(color = Color(0xFF10B981).copy(alpha = 0.2f), shape = RoundedCornerShape(20.dp)) {
                            Row(modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.FiberManualRecord, null, tint = Color(0xFF10B981), modifier = Modifier.size(8.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                val isTrackingPaused = myLoc?.isPaused == true
                                Text(if (isTrackingPaused) "Paused" else "Live", color = if (isTrackingPaused) Color(0xFFF59E0B) else Color(0xFF10B981), fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                        Surface(color = Color(0xFF818CF8).copy(alpha = 0.2f), shape = RoundedCornerShape(20.dp)) {
                            Text("${memberLocations.size} Riders", modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp), color = Color(0xFF818CF8), fontSize = 11.sp, fontWeight = FontWeight.Bold)
                        }
                        if (activeGroup?.nextStopPoint?.isNotBlank() == true) {
                            Surface(
                                color = Color(0xFF3B82F6).copy(alpha = 0.2f), shape = RoundedCornerShape(20.dp),
                                modifier = Modifier.clickable {
                                    val nextStop = activeGroup?.nextStopPoint ?: ""
                                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=${Uri.encode(nextStop)}"))
                                    intent.setPackage("com.google.android.apps.maps")
                                    try { context.startActivity(intent) } catch (e: Exception) {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/maps/search/${Uri.encode(nextStop)}")))
                                    }
                                }
                            ) {
                                Row(modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.Navigation, null, tint = Color(0xFF3B82F6), modifier = Modifier.size(12.dp))
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text(activeGroup?.nextStopPoint ?: "", color = Color(0xFF3B82F6), fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }

                    // Wait warning overlay banner
                    AnimatedVisibility(visible = activeTimerText != null) {
                        Surface(color = Color(0xFFF59E0B), modifier = Modifier.fillMaxWidth()) {
                            Row(modifier = Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.HourglassTop, null, tint = Color.White, modifier = Modifier.size(20.dp))
                                Spacer(modifier = Modifier.width(8.dp))
                                Text("Wait by $activeTimerRequester: Stop in $activeTimerText!", color = Color.White, fontWeight = FontWeight.ExtraBold, fontSize = 14.sp)
                            }
                        }
                    }

                    // SOS warning overlay banner
                    AnimatedVisibility(visible = otherSOSAlerts.isNotEmpty()) {
                        val latestAlert = otherSOSAlerts.lastOrNull()
                        if (latestAlert != null) {
                            Surface(color = Color(0xFFDC2626), modifier = Modifier.fillMaxWidth()) {
                                Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.Warning, "SOS", tint = Color.White, modifier = Modifier.size(24.dp))
                                    Spacer(modifier = Modifier.width(8.dp))
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text("SOS: ${latestAlert.userName}", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                        Text("Needs help!", color = Color.White.copy(alpha = 0.9f), fontSize = 12.sp)
                                    }
                                    Button(
                                        onClick = {
                                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=${latestAlert.latitude},${latestAlert.longitude}"))
                                            intent.setPackage("com.google.android.apps.maps")
                                            try { context.startActivity(intent) } catch (e: Exception) {
                                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/maps?q=${latestAlert.latitude},${latestAlert.longitude}")))
                                            }
                                        },
                                        colors = ButtonDefaults.buttonColors(containerColor = Color.White),
                                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                                    ) { Text("Navigate", color = Color(0xFFDC2626), fontWeight = FontWeight.Bold, fontSize = 12.sp) }
                                    Spacer(modifier = Modifier.width(4.dp))
                                    IconButton(onClick = { viewModel.resolveSOS(latestAlert.alertId) }) {
                                        Icon(Icons.Default.Check, "Resolve", tint = Color.White)
                                    }
                                }
                            }
                        }
                    }

                    // Co-riding assignment banner if enabled in safety profile
                    if (myLoc?.isCoRiding == true) {
                        val companionText = if (myLoc.ridingWithUserName.isNotBlank()) myLoc.ridingWithUserName else "None Selected"
                        Surface(
                            color = Color(0xFF3B82F6).copy(alpha = 0.15f),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.People, null, tint = Color(0xFF60A5FA), modifier = Modifier.size(16.dp))
                                    Spacer(modifier = Modifier.width(8.dp))
                                    Text("Co-riding with: ", color = Color(0xFF93C5FD), fontSize = 13.sp)
                                    Text(companionText, color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                                }
                                Text(
                                    text = "Change",
                                    color = Color(0xFF60A5FA),
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.clickable { showCoRiderSelectionDialog = true }
                                )
                            }
                        }
                    }

                    // Tab selections
                    TabRow(
                        selectedTabIndex = selectedTab,
                        containerColor = cardColor,
                        contentColor = Color(0xFF818CF8),
                        indicator = { tabPositions ->
                            TabRowDefaults.SecondaryIndicator(
                                Modifier.tabIndicatorOffset(tabPositions[selectedTab]),
                                color = Color(0xFF818CF8)
                            )
                        }
                    ) {
                        Tab(selected = selectedTab == 0, onClick = { selectedTab = 0 },
                            text = { Text("Riders (${memberLocations.size})", fontSize = 13.sp) },
                            selectedContentColor = Color(0xFF818CF8), unselectedContentColor = textSecondary)
                        Tab(selected = selectedTab == 1, onClick = { selectedTab = 1 },
                            text = {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("Conversation Chat", fontSize = 13.sp)
                                    if (activeMessages.isNotEmpty()) {
                                        Spacer(modifier = Modifier.width(6.dp))
                                        Surface(color = Color(0xFFEF4444), shape = CircleShape) {
                                            Text("${activeMessages.size}", modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp), color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                                        }
                                    }
                                }
                            },
                            selectedContentColor = Color(0xFF818CF8), unselectedContentColor = textSecondary)
                        Tab(selected = selectedTab == 2, onClick = { selectedTab = 2 },
                            text = { Text("Stops (${activeGroup?.stopPoints?.size ?: 0})", fontSize = 13.sp) },
                            selectedContentColor = Color(0xFF818CF8), unselectedContentColor = textSecondary)
                    }
                }
            }
        },
        bottomBar = {
            if (selectedTab == 0) {
                Surface(color = cardColor, shadowElevation = 8.dp) {
                    Column(modifier = Modifier.navigationBarsPadding()) {
                        // Safety actions row: SOS, Wait, Msg, Next Stop
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 10.dp),
                            horizontalArrangement = Arrangement.SpaceEvenly,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            // SOS
                            FilledTonalButton(
                                onClick = { showSOSConfirmation = true },
                                colors = ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFFDC2626).copy(alpha = 0.2f)),
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                            ) {
                                Icon(Icons.Default.Warning, null, tint = Color(0xFFEF4444), modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("SOS", color = Color(0xFFEF4444), fontWeight = FontWeight.Bold, fontSize = 12.sp)
                            }
                            // Wait
                            var showWaitDialog by remember { mutableStateOf(false) }
                            FilledTonalButton(
                                onClick = { showWaitDialog = true },
                                colors = ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFFF59E0B).copy(alpha = 0.2f)),
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                            ) {
                                Icon(Icons.Default.HourglassTop, null, tint = Color(0xFFF59E0B), modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("Wait", color = Color(0xFFF59E0B), fontWeight = FontWeight.Bold, fontSize = 12.sp)
                            }
                            if (showWaitDialog) {
                                AlertDialog(
                                    onDismissRequest = { showWaitDialog = false },
                                    title = { Text("Request Wait", color = textPrimary, fontWeight = FontWeight.Bold) },
                                    text = {
                                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                            Text("All members will be notified to stop in 2 minutes.", color = textSecondary, fontSize = 13.sp)
                                            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                                listOf(2, 5, 10, 15).forEach { mins ->
                                                    Button(
                                                        onClick = { viewModel.requestWait(mins); showWaitDialog = false; Toast.makeText(context, "Wait request sent!", Toast.LENGTH_SHORT).show() },
                                                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFF59E0B)),
                                                        modifier = Modifier.weight(1f), contentPadding = PaddingValues(0.dp)
                                                    ) { Text("${mins}m", fontSize = 13.sp, fontWeight = FontWeight.Bold) }
                                                }
                                            }
                                        }
                                    },
                                    confirmButton = {},
                                    dismissButton = { TextButton(onClick = { showWaitDialog = false }) { Text("Cancel", color = textPrimary) } },
                                    containerColor = cardColor
                                )
                            }
                            // Broadcast
                            FilledTonalButton(
                                onClick = { showMessageDialog = true },
                                colors = ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFF818CF8).copy(alpha = 0.2f)),
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                            ) {
                                Icon(Icons.Default.Campaign, null, tint = Color(0xFF818CF8), modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("Broadcast", color = Color(0xFF818CF8), fontWeight = FontWeight.Bold, fontSize = 12.sp)
                            }
                            // Next Stop
                            if (activeGroup?.createdBy == viewModel.currentUserId) {
                                FilledTonalButton(
                                    onClick = { showNextStopDialog = true },
                                    colors = ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFF3B82F6).copy(alpha = 0.2f)),
                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                                ) {
                                    Icon(Icons.Default.Navigation, null, tint = Color(0xFF3B82F6), modifier = Modifier.size(18.dp))
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text("Next Stop", color = Color(0xFF3B82F6), fontWeight = FontWeight.Bold, fontSize = 12.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    ) { innerPadding ->
        when (selectedTab) {
            0 -> {
                // TAB 0: RIDERS LIST WITH EMBEDDED OPENSTREETMAP
                Column(
                    modifier = Modifier.fillMaxSize().padding(innerPadding)
                ) {
                    // TRIP LIFECYCLE BUTTONS ROW (synced from Firebase)
                    val groupTripState = activeGroup?.groupTripState ?: "NOT_STARTED"
                    val isPendingMember = activeGroup?.pendingMembers?.containsKey(viewModel.currentUserId) == true
                    val isApprovedMember = activeGroup?.members?.containsKey(viewModel.currentUserId) == true
                    val isProfileCompleted by viewModel.isProfileCompleted.collectAsState()

                    // Auto-start/stop tracking service based on group trip state
                    LaunchedEffect(groupTripState) {
                        when (groupTripState) {
                            "STARTED" -> {
                                viewModel.saveTripState("STARTED")
                                val intent = Intent(context, TrackingService::class.java).apply {
                                    action = TrackingService.ACTION_START
                                    putExtra(TrackingService.EXTRA_GROUP_ID, viewModel.getSavedGroupId())
                                    putExtra(TrackingService.EXTRA_USER_ID, viewModel.currentUserId)
                                }
                                context.startService(intent)
                            }
                            "PAUSED" -> {
                                viewModel.saveTripState("PAUSED")
                            }
                            "STOPPED" -> {
                                viewModel.saveTripState("STOPPED")
                                val intent = Intent(context, TrackingService::class.java).apply {
                                    action = TrackingService.ACTION_STOP
                                }
                                context.startService(intent)
                            }
                        }
                    }

                    // Pending member approval overlay
                    if (isPendingMember && !isApprovedMember) {
                        Box(
                            modifier = Modifier.fillMaxSize(),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                CircularProgressIndicator(color = Color(0xFF6366F1))
                                Spacer(modifier = Modifier.height(16.dp))
                                Text("Waiting for admin approval...", color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                                Spacer(modifier = Modifier.height(8.dp))
                                Text("The group admin will approve your request shortly.", color = textSecondary, fontSize = 14.sp)
                                Spacer(modifier = Modifier.height(24.dp))
                                OutlinedButton(onClick = {
                                    viewModel.leaveGroup()
                                    onNavigateBack()
                                }) {
                                    Text("Cancel & Leave")
                                }
                            }
                        }
                        return@Scaffold
                    }

                    // Admin: Pending members approval banner
                    val pendingMembers = activeGroup?.pendingMembers ?: emptyMap()
                    if (isGroupAdmin && pendingMembers.isNotEmpty()) {
                        Card(
                            colors = CardDefaults.cardColors(containerColor = Color(0xFF312E81)),
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 4.dp)
                        ) {
                            Column(modifier = Modifier.padding(12.dp)) {
                                Text("📋 Pending Join Requests (${pendingMembers.size})", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                Spacer(modifier = Modifier.height(8.dp))
                                pendingMembers.forEach { (userId, memberName) ->
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Surface(color = Color(0xFF6366F1), shape = CircleShape, modifier = Modifier.size(32.dp)) {
                                            Box(contentAlignment = Alignment.Center) {
                                                Text(memberName.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                            }
                                        }
                                        Spacer(modifier = Modifier.width(10.dp))
                                        Text(memberName, color = Color.White, fontWeight = FontWeight.Medium, fontSize = 14.sp, modifier = Modifier.weight(1f))
                                        IconButton(onClick = { viewModel.approveMember(userId) }, modifier = Modifier.size(36.dp)) {
                                            Icon(Icons.Default.CheckCircle, "Approve", tint = Color(0xFF10B981))
                                        }
                                        IconButton(onClick = { viewModel.rejectMember(userId) }, modifier = Modifier.size(36.dp)) {
                                            Icon(Icons.Default.Cancel, "Reject", tint = Color(0xFFEF4444))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Trip control row
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (isGroupAdmin) {
                            // Admin controls
                            when (groupTripState) {
                                "STARTED" -> {
                                    Button(
                                        onClick = {
                                            viewModel.saveTripState("PAUSED")
                                            Toast.makeText(context, "Trip Paused for all.", Toast.LENGTH_SHORT).show()
                                        },
                                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFF59E0B)),
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Text("Pause Trip", color = Color.White)
                                    }
                                    
                                    Button(
                                        onClick = {
                                            viewModel.saveTripState("STOPPED")
                                            val intent = Intent(context, TrackingService::class.java).apply {
                                                action = TrackingService.ACTION_STOP
                                            }
                                            context.startService(intent)
                                            Toast.makeText(context, "Trip Stopped for all.", Toast.LENGTH_SHORT).show()
                                        },
                                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444)),
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Text("Stop Trip", color = Color.White)
                                    }
                                }
                                "PAUSED" -> {
                                    Button(
                                        onClick = {
                                            viewModel.saveTripState("STARTED")
                                            val intent = Intent(context, TrackingService::class.java).apply {
                                                action = TrackingService.ACTION_START
                                                putExtra(TrackingService.EXTRA_GROUP_ID, viewModel.getSavedGroupId())
                                                putExtra(TrackingService.EXTRA_USER_ID, viewModel.currentUserId)
                                            }
                                            context.startService(intent)
                                            Toast.makeText(context, "Trip Resumed for all.", Toast.LENGTH_SHORT).show()
                                        },
                                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF10B981)),
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Text("Resume Trip", color = Color.White)
                                    }
                                    
                                    Button(
                                        onClick = {
                                            viewModel.saveTripState("STOPPED")
                                            val intent = Intent(context, TrackingService::class.java).apply {
                                                action = TrackingService.ACTION_STOP
                                            }
                                            context.startService(intent)
                                            Toast.makeText(context, "Trip Stopped for all.", Toast.LENGTH_SHORT).show()
                                        },
                                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444)),
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Text("Stop Trip", color = Color.White)
                                    }
                                }
                                else -> { // "NOT_STARTED" or "STOPPED"
                                    Button(
                                        onClick = {
                                            if (!isProfileCompleted) {
                                                Toast.makeText(context, "Please complete your Safety Profile first!", Toast.LENGTH_LONG).show()
                                                showProfileDialogDashboard = true
                                            } else {
                                                viewModel.saveTripState("STARTED")
                                                val intent = Intent(context, TrackingService::class.java).apply {
                                                    action = TrackingService.ACTION_START
                                                    putExtra(TrackingService.EXTRA_GROUP_ID, viewModel.getSavedGroupId())
                                                    putExtra(TrackingService.EXTRA_USER_ID, viewModel.currentUserId)
                                                }
                                                context.startService(intent)
                                                Toast.makeText(context, "Trip Started for all. Tracking location...", Toast.LENGTH_SHORT).show()
                                            }
                                        },
                                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF10B981)),
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Text("Start Trip", color = Color.White)
                                    }
                                }
                            }
                        } else {
                            // Non-admin: read-only status chip
                            val (statusText, statusColor, statusIcon) = when (groupTripState) {
                                "STARTED" -> Triple("🟢 Trip Active", Color(0xFF10B981), Icons.Default.PlayArrow)
                                "PAUSED" -> Triple("⏸ Trip Paused", Color(0xFFF59E0B), Icons.Default.Pause)
                                "STOPPED" -> Triple("🔴 Trip Stopped", Color(0xFFEF4444), Icons.Default.Stop)
                                else -> Triple("⏳ Waiting to Start", Color(0xFF6366F1), Icons.Default.Schedule)
                            }
                            Surface(
                                color = statusColor.copy(alpha = 0.15f),
                                shape = RoundedCornerShape(12.dp),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(statusIcon, null, tint = statusColor, modifier = Modifier.size(20.dp))
                                    Spacer(modifier = Modifier.width(8.dp))
                                    Text(statusText, color = statusColor, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                                }
                            }
                        }
                    }

                    // Distance Alert Warning Banner
                    activeDistanceAlerts.firstOrNull { !it.resolved }?.let { alert ->
                        val bannerBgColor = if (alert.level == "CRITICAL") Color(0xFFFEE2E2) else Color(0xFFFEF3C7)
                        val bannerTextColor = if (alert.level == "CRITICAL") Color(0xFF991B1B) else Color(0xFF92400E)
                        val bannerIcon = if (alert.level == "CRITICAL") Icons.Default.Warning else Icons.Default.Info
                        
                        Surface(
                            color = bannerBgColor,
                            shape = RoundedCornerShape(8.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 6.dp)
                        ) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(bannerIcon, contentDescription = null, tint = bannerTextColor, modifier = Modifier.size(20.dp))
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(
                                    text = "${alert.userName} is falling behind! (Distance: ${String.format("%.1f", alert.distance)} km)",
                                    color = bannerTextColor,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.weight(1f)
                                )
                            }
                        }
                    }

                    // Sort riders list by distance from lead
                    val sortedRiders = remember(memberLocations) {
                        val list = memberLocations.entries.toList()
                        val leadEntry = list.firstOrNull { it.value.ridingRole.uppercase() == "LEAD" }
                        if (leadEntry != null) {
                            val leadLoc = leadEntry.value
                            list.sortedWith(Comparator { o1, o2 ->
                                val r1 = o1.value.ridingRole.uppercase()
                                val r2 = o2.value.ridingRole.uppercase()
                                
                                when {
                                    r1 == "LEAD" && r2 != "LEAD" -> -1
                                    r2 == "LEAD" && r1 != "LEAD" -> 1
                                    r1 == "SWEEP" && r2 != "SWEEP" -> 1
                                    r2 == "SWEEP" && r1 != "SWEEP" -> -1
                                    else -> {
                                        // Both are MIDDLE: sort by distance from Lead
                                        val d1 = calculateDistanceKm(leadLoc.lat, leadLoc.lng, o1.value.lat, o1.value.lng)
                                        val d2 = calculateDistanceKm(leadLoc.lat, leadLoc.lng, o2.value.lat, o2.value.lng)
                                        d1.compareTo(d2)
                                    }
                                }
                            })
                        } else {
                            // Sort by distance from current user
                            val myEntry = list.firstOrNull { it.key == viewModel.currentUserId }
                            if (myEntry != null && myEntry.value.lat != 0.0 && myEntry.value.lng != 0.0) {
                                val myLocVal = myEntry.value
                                list.sortedWith(Comparator { o1, o2 ->
                                    when {
                                        o1.key == viewModel.currentUserId && o2.key != viewModel.currentUserId -> -1
                                        o2.key == viewModel.currentUserId && o1.key != viewModel.currentUserId -> 1
                                        else -> {
                                            val d1 = calculateDistanceKm(myLocVal.lat, myLocVal.lng, o1.value.lat, o1.value.lng)
                                            val d2 = calculateDistanceKm(myLocVal.lat, myLocVal.lng, o2.value.lat, o2.value.lng)
                                            d1.compareTo(d2)
                                        }
                                    }
                                })
                            } else {
                                list
                            }
                        }
                    }

                    val activeSosUserIds = remember(activeSOSAlerts) {
                        activeSOSAlerts.filter { !it.resolved }.map { it.targetUserId }.toSet()
                    }

                    OpenStreetMap(
                        memberLocations = memberLocations,
                        myLoc = myLoc,
                        activeSosUserIds = activeSosUserIds,
                        activeGroup = activeGroup,
                        onMarkerClick = { clickedLoc ->
                            selectedMember = clickedLoc
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(0.4f)
                    )
                    
                    LazyColumn(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(0.6f)
                            .padding(horizontal = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        contentPadding = PaddingValues(vertical = 12.dp)
                    ) {
                        items(sortedRiders) { (userId, loc) ->
                            val isSelf = userId == viewModel.currentUserId
                            val distText = if (isSelf) {
                                "You"
                            } else if (myLoc != null && loc.lat != 0.0 && loc.lng != 0.0) {
                                val dist = calculateDistanceKm(loc.lat, loc.lng, myLoc.lat, myLoc.lng)
                                if (dist < 1.0) String.format("%.0f m", dist * 1000) else String.format("%.1f km", dist)
                            } else "..."

                            Card(
                                colors = CardDefaults.cardColors(containerColor = if (isSelf) selfCardColor else cardColor),
                                shape = RoundedCornerShape(16.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        selectedMember = loc
                                    }
                            ) {
                                Row(
                                    modifier = Modifier.padding(14.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    val badgeColor = when (loc.ridingRole.uppercase()) {
                                        "LEAD" -> Color(0xFFEF4444)
                                        "SWEEP" -> Color(0xFF10B981)
                                        else -> Color(0xFF6366F1)
                                    }
                                    Surface(
                                        color = badgeColor,
                                        shape = CircleShape,
                                        modifier = Modifier.size(44.dp)
                                    ) {
                                        Box(contentAlignment = Alignment.Center) {
                                            Text(loc.userName.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                                        }
                                    }
                                    Spacer(modifier = Modifier.width(12.dp))
                                    Column(modifier = Modifier.weight(1f)) {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Text(loc.userName, color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                                            
                                            // Role Badge
                                            if (loc.ridingRole.isNotBlank()) {
                                                Spacer(modifier = Modifier.width(6.dp))
                                                Surface(
                                                    color = when (loc.ridingRole.uppercase()) {
                                                        "LEAD" -> Color(0xFFEF4444).copy(alpha = 0.2f)
                                                        "SWEEP" -> Color(0xFF10B981).copy(alpha = 0.2f)
                                                        else -> Color(0xFF6366F1).copy(alpha = 0.2f)
                                                    },
                                                    shape = RoundedCornerShape(4.dp)
                                                ) {
                                                    Text(
                                                        text = loc.ridingRole.uppercase(),
                                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp),
                                                        color = when (loc.ridingRole.uppercase()) {
                                                            "LEAD" -> Color(0xFFEF4444)
                                                            "SWEEP" -> Color(0xFF10B981)
                                                            else -> Color(0xFF818CF8)
                                                        },
                                                        fontSize = 9.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                }
                                            }

                                            if (isSelf) {
                                                Spacer(modifier = Modifier.width(6.dp))
                                                Surface(color = Color(0xFF818CF8).copy(alpha = 0.3f), shape = RoundedCornerShape(4.dp)) {
                                                    Text("YOU", modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp), color = Color(0xFF818CF8), fontSize = 9.sp, fontWeight = FontWeight.Bold)
                                                }
                                            }
                                            if (loc.isCoRiding) {
                                                Spacer(modifier = Modifier.width(6.dp))
                                                Surface(color = Color(0xFF3B82F6).copy(alpha = 0.2f), shape = RoundedCornerShape(4.dp)) {
                                                    val companion = if (loc.ridingWithUserName.isNotBlank()) loc.ridingWithUserName else "Rider"
                                                    Text("Co-riding with $companion", modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp), color = Color(0xFF93C5FD), fontSize = 9.sp)
                                                }
                                            }
                                            if (loc.isPaused) {
                                                Spacer(modifier = Modifier.width(6.dp))
                                                Surface(color = Color(0xFFF59E0B).copy(alpha = 0.2f), shape = RoundedCornerShape(4.dp)) {
                                                    Text("PAUSED", modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp), color = Color(0xFFF59E0B), fontSize = 9.sp, fontWeight = FontWeight.Bold)
                                                }
                                            }
                                        }
                                        Spacer(modifier = Modifier.height(4.dp))
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            val speedDisplay = if (loc.isPaused) "Paused" else "${String.format("%.1f", loc.speed)} km/h"
                                            Text(speedDisplay, color = textSecondary, fontSize = 12.sp)
                                            Text(" · ", color = dividerColor, fontSize = 12.sp)
                                            Icon(
                                                imageVector = if (loc.battery > 50) Icons.Default.BatteryFull else if (loc.battery > 20) Icons.Default.BatteryChargingFull else Icons.Default.BatteryAlert,
                                                contentDescription = null,
                                                tint = if (loc.battery > 50) Color(0xFF10B981) else if (loc.battery > 20) Color(0xFFF59E0B) else Color(0xFFEF4444),
                                                modifier = Modifier.size(14.dp)
                                            )
                                            Text("${loc.battery}%", color = textSecondary, fontSize = 12.sp)
                                            if (!loc.isCoRiding && loc.vehicleNo.isNotBlank()) {
                                                Text(" · ", color = dividerColor, fontSize = 12.sp)
                                                Text(loc.vehicleNo, color = textSecondary, fontSize = 12.sp)
                                            }
                                        }
                                    }
                                    Column(horizontalAlignment = Alignment.End) {
                                        Text(distText, color = if (isSelf) Color(0xFF818CF8) else Color(0xFF10B981), fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                        // Phone number row
                                        if (loc.phoneNumber.isNotBlank()) {
                                            Row(
                                                verticalAlignment = Alignment.CenterVertically,
                                                modifier = Modifier
                                                    .padding(top = 2.dp)
                                                    .clickable {
                                                        val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${loc.phoneNumber}"))
                                                        context.startActivity(intent)
                                                    }
                                            ) {
                                                Icon(Icons.Default.Phone, null, tint = Color(0xFF10B981), modifier = Modifier.size(12.dp))
                                                Spacer(modifier = Modifier.width(3.dp))
                                                Text(loc.phoneNumber, color = Color(0xFF10B981), fontSize = 11.sp)
                                            }
                                        }
                                        // Emergency contact row
                                        if (loc.emergencyContact.isNotBlank()) {
                                            Row(
                                                verticalAlignment = Alignment.CenterVertically,
                                                modifier = Modifier
                                                    .padding(top = 2.dp)
                                                    .clickable {
                                                        val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${loc.emergencyContact}"))
                                                        context.startActivity(intent)
                                                    }
                                            ) {
                                                Icon(Icons.Default.LocalHospital, null, tint = Color(0xFFEF4444), modifier = Modifier.size(12.dp))
                                                Spacer(modifier = Modifier.width(3.dp))
                                                Text(loc.emergencyContact, color = Color(0xFFEF4444), fontSize = 11.sp)
                                            }
                                        }
                                        // Navigate button
                                        if (!isSelf && loc.lat != 0.0 && loc.lng != 0.0) {
                                            Surface(
                                                color = Color(0xFF3B82F6).copy(alpha = 0.2f),
                                                shape = RoundedCornerShape(8.dp),
                                                modifier = Modifier
                                                    .padding(top = 4.dp)
                                                    .clickable {
                                                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=${loc.lat},${loc.lng}"))
                                                        intent.setPackage("com.google.android.apps.maps")
                                                        try { context.startActivity(intent) } catch (e: Exception) {
                                                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/maps?q=${loc.lat},${loc.lng}")))
                                                        }
                                                    }
                                            ) {
                                                Row(modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                                    Icon(Icons.Default.Navigation, null, tint = Color(0xFF3B82F6), modifier = Modifier.size(12.dp))
                                                    Spacer(modifier = Modifier.width(3.dp))
                                                    Text("Map", color = Color(0xFF3B82F6), fontSize = 11.sp, fontWeight = FontWeight.Bold)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            1 -> {
                // TAB 1: GROUP CHAT CONVERSATIONS VIEW
                val listState = rememberLazyListState()
                LaunchedEffect(activeMessages.size) {
                    if (activeMessages.isNotEmpty()) {
                        listState.animateScrollToItem(0)
                    }
                }

                Column(
                    modifier = Modifier.fillMaxSize().padding(innerPadding).background(bgColor)
                ) {
                    // Chat thread
                    LazyColumn(
                        state = listState,
                        modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        contentPadding = PaddingValues(vertical = 12.dp),
                        reverseLayout = true // Show latest at the bottom
                    ) {
                        items(activeMessages.sortedByDescending { it.timestamp }) { msg ->
                            val isMine = msg.senderId == viewModel.currentUserId
                            val priorityColor = when (msg.priority) { "High" -> Color(0xFFEF4444); "Medium" -> Color(0xFFF59E0B); else -> Color(0xFF64748B) }

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = if (isMine) Arrangement.End else Arrangement.Start
                            ) {
                                Column(
                                    modifier = Modifier.widthIn(max = 280.dp),
                                    horizontalAlignment = if (isMine) Alignment.End else Alignment.Start
                                ) {
                                    if (!isMine) {
                                        Text(msg.senderName, color = textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 4.dp, bottom = 2.dp))
                                    }
                                    Surface(
                                        color = if (isMine) myBubbleColor else cardColor,
                                        shape = RoundedCornerShape(
                                            topStart = 12.dp, topEnd = 12.dp,
                                            bottomStart = if (isMine) 12.dp else 2.dp,
                                            bottomEnd = if (isMine) 2.dp else 12.dp
                                        ),
                                        tonalElevation = 1.dp
                                    ) {
                                        Column(modifier = Modifier.padding(10.dp)) {
                                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                                if (msg.priority != "Low") {
                                                    Icon(
                                                        imageVector = if (msg.priority == "High") Icons.Default.Campaign else Icons.Default.Notifications,
                                                        contentDescription = null,
                                                        tint = priorityColor,
                                                        modifier = Modifier.size(13.dp)
                                                    )
                                                }
                                                Text(msg.content, color = textPrimary, fontSize = 14.sp)
                                            }
                                        }
                                    }
                                    val timeStr = remember(msg.timestamp) {
                                        SimpleDateFormat("hh:mm a", Locale.getDefault()).format(Date(msg.timestamp))
                                    }
                                    Text(timeStr, color = textSecondary, fontSize = 9.sp, modifier = Modifier.padding(top = 2.dp, start = 4.dp, end = 4.dp))
                                }
                            }
                        }
                    }

                    // Quick Message template Row
                    Surface(color = cardColor.copy(alpha = 0.5f), modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(vertical = 8.dp)) {
                            Text("QUICK MESSAGES", color = Color(0xFF818CF8), fontSize = 9.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 12.dp, end = 12.dp, bottom = 6.dp))
                            LazyColumn(
                                modifier = Modifier.fillMaxWidth().height(48.dp),
                                contentPadding = PaddingValues(horizontal = 12.dp)
                            ) {
                                item {
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        quickMessages.forEach { (label, contentPriority) ->
                                            val (text, priority) = contentPriority
                                            SuggestionChip(
                                                onClick = {
                                                    viewModel.sendGroupMessage(text, priority)
                                                    Toast.makeText(context, "Sent: $text", Toast.LENGTH_SHORT).show()
                                                },
                                                label = { Text(label, color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 12.sp) },
                                                colors = SuggestionChipDefaults.suggestionChipColors(containerColor = dividerColor)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Chat Input Box bar
                    Surface(color = cardColor, modifier = Modifier.fillMaxWidth()) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            var chatInputText by remember { mutableStateOf("") }
                            OutlinedTextField(
                                value = chatInputText,
                                onValueChange = { chatInputText = it },
                                placeholder = { Text("Send a message...", color = textSecondary, fontSize = 14.sp) },
                                modifier = Modifier.weight(1f).padding(end = 8.dp),
                                maxLines = 2,
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = Color(0xFF818CF8),
                                    unfocusedBorderColor = dividerColor,
                                    focusedTextColor = textPrimary,
                                    unfocusedTextColor = textPrimary
                                ),
                                shape = RoundedCornerShape(24.dp)
                            )
                            IconButton(
                                onClick = {
                                    if (chatInputText.isNotBlank()) {
                                        viewModel.sendGroupMessage(chatInputText.trim(), "Medium")
                                        chatInputText = ""
                                    }
                                },
                                modifier = Modifier.background(Color(0xFF6366F1), CircleShape).size(40.dp)
                            ) {
                                Icon(Icons.Default.Send, null, tint = Color.White, modifier = Modifier.size(18.dp))
                            }
                        }
                    }
                }
            }
            2 -> {
                // TAB 2: STOPS TIMELINE VIEW
                val stopsList = activeGroup?.stopPoints ?: emptyList()
                val start = activeGroup?.startPoint ?: "Start Location"
                val destination = activeGroup?.destination ?: "Destination"
                val isCreator = activeGroup?.createdBy == viewModel.currentUserId

                var showAddStopDialog by remember { mutableStateOf(false) }
                var newStopName by remember { mutableStateOf("") }

                if (showAddStopDialog) {
                    AlertDialog(
                        onDismissRequest = { showAddStopDialog = false },
                        title = { Text("Add Stop Point", color = textPrimary, fontWeight = FontWeight.Bold) },
                        text = {
                            LocationAutoCompleteTextField(
                                value = newStopName,
                                onValueChange = { newStopName = it },
                                label = "Stop Name/Address",
                                leadingIcon = { Icon(Icons.Default.PinDrop, contentDescription = null, tint = Color(0xFFFBBF24)) },
                                textPrimary = textPrimary,
                                textSecondary = textSecondary,
                                cardColor = cardColor,
                                dividerColor = dividerColor,
                                modifier = Modifier.fillMaxWidth()
                            )
                        },
                        confirmButton = {
                            Button(
                                onClick = {
                                    if (newStopName.isNotBlank()) {
                                        viewModel.addStopPoint(newStopName.trim())
                                        newStopName = ""
                                        showAddStopDialog = false
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF818CF8)),
                                enabled = newStopName.isNotBlank()
                            ) {
                                Text("Add")
                            }
                        },
                        dismissButton = {
                            TextButton(onClick = { showAddStopDialog = false }) {
                                Text("Cancel", color = textSecondary)
                            }
                        },
                        containerColor = cardColor
                    )
                }

                Column(
                    modifier = Modifier.fillMaxSize().padding(innerPadding).background(bgColor).padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    LazyColumn(
                        modifier = Modifier.weight(1f).fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        // Start point node
                        item {
                            RouteTimelineNode(
                                title = "Start Point",
                                address = start,
                                isCompleted = true,
                                icon = Icons.Default.TripOrigin,
                                iconColor = Color(0xFF10B981),
                                textPrimary = textPrimary,
                                textSecondary = textSecondary,
                                cardColor = cardColor,
                                dividerColor = dividerColor,
                                context = context
                            )
                        }

                        // Intermediate stop points
                        itemsIndexed(stopsList) { index, stopName ->
                            RouteTimelineNode(
                                title = "Stop #${index + 1}",
                                address = stopName,
                                isCompleted = false,
                                icon = Icons.Default.Place,
                                iconColor = Color(0xFFF59E0B),
                                textPrimary = textPrimary,
                                textSecondary = textSecondary,
                                cardColor = cardColor,
                                dividerColor = dividerColor,
                                context = context,
                                onDelete = if (isCreator) { { viewModel.removeStopPoint(index) } } else null
                            )
                        }

                        // Destination point node
                        item {
                            RouteTimelineNode(
                                title = "Destination",
                                address = destination,
                                isCompleted = false,
                                icon = Icons.Default.Flag,
                                iconColor = Color(0xFFEF4444),
                                textPrimary = textPrimary,
                                textSecondary = textSecondary,
                                cardColor = cardColor,
                                dividerColor = dividerColor,
                                context = context
                            )
                        }
                    }

                    if (isCreator) {
                        Spacer(modifier = Modifier.height(12.dp))
                        Button(
                            onClick = { showAddStopDialog = true },
                            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF818CF8)),
                            modifier = Modifier.fillMaxWidth().height(48.dp),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Icon(Icons.Default.Add, contentDescription = null, tint = Color.White)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Add Stop Point", color = Color.White, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }

    // ========================
    // DIALOGS
    // ========================

    // Co-Rider Selection Dialog
    if (showCoRiderSelectionDialog) {
        val riderList = memberLocations.filter { it.key != viewModel.currentUserId && !it.value.isCoRiding }.values.toList()
        AlertDialog(
            onDismissRequest = { showCoRiderSelectionDialog = false },
            title = { Text("Select Your Rider", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Select the member you are co-riding (pillion) with. You can change this at any time.", color = textSecondary, fontSize = 13.sp)
                    if (riderList.isEmpty()) {
                        Text("No active riders in group yet.", color = textSecondary, fontSize = 13.sp, modifier = Modifier.padding(vertical = 12.dp))
                    } else {
                        LazyColumn(
                            modifier = Modifier.fillMaxWidth().heightIn(max = 200.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            items(riderList) { rider ->
                                val riderId = memberLocations.entries.firstOrNull { it.value.userName == rider.userName }?.key ?: ""
                                Card(
                                    colors = CardDefaults.cardColors(containerColor = dividerColor),
                                    modifier = Modifier.fillMaxWidth().clickable {
                                        viewModel.updateVehicleProfile(
                                            vehicleType = "Pillion Rider",
                                            vehicleNo = "Riding with ${rider.userName}",
                                            vehicleColor = "N/A",
                                            phoneNumber = viewModel.getSavedPhone() ?: "",
                                            emergencyContact = myLoc?.emergencyContact ?: "",
                                            isCoRiding = true,
                                            ridingWithUserId = riderId,
                                            ridingWithUserName = rider.userName
                                        )
                                        showCoRiderSelectionDialog = false
                                        Toast.makeText(context, "Associated with rider ${rider.userName}!", Toast.LENGTH_SHORT).show()
                                    }
                                ) {
                                    Column(modifier = Modifier.padding(12.dp)) {
                                        Text(rider.userName, color = textPrimary, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                                        val bikeInfo = if (rider.vehicleType.isNotBlank() || rider.vehicleNo.isNotBlank()) {
                                            listOfNotNull(
                                                rider.vehicleType.takeIf { it.isNotBlank() },
                                                rider.vehicleNo.takeIf { it.isNotBlank() },
                                                rider.vehicleColor.takeIf { it.isNotBlank() && it != "N/A" }
                                            ).joinToString(" · ")
                                        } else {
                                            "No vehicle details registered"
                                        }
                                        Text(bikeInfo, color = textSecondary, fontSize = 12.sp)
                                    }
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { showCoRiderSelectionDialog = false }) {
                    Text("Cancel", color = textSecondary)
                }
            },
            containerColor = cardColor
        )
    }

    // Broadcast Message Dialog
    if (showMessageDialog) {
        AlertDialog(
            onDismissRequest = { showMessageDialog = false },
            title = { Text("Broadcast Message", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = messageText, onValueChange = { messageText = it },
                        label = { Text("Your message", color = textSecondary) },
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Color(0xFF818CF8), unfocusedBorderColor = dividerColor, focusedTextColor = textPrimary, unfocusedTextColor = textPrimary),
                        maxLines = 3
                    )
                    Text("Priority Level:", color = textSecondary, fontSize = 13.sp)
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("Low" to Color(0xFF64748B), "Medium" to Color(0xFFF59E0B), "High" to Color(0xFFEF4444)).forEach { (p, c) ->
                            FilterChip(
                                selected = messagePriority == p,
                                onClick = { messagePriority = p },
                                label = { Text(p, fontSize = 12.sp, fontWeight = FontWeight.Bold) },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = c.copy(alpha = 0.3f),
                                    selectedLabelColor = c,
                                    containerColor = dividerColor,
                                    labelColor = textSecondary
                                ),
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                    if (messagePriority == "High") {
                        Surface(color = Color(0xFFEF4444).copy(alpha = 0.1f), shape = RoundedCornerShape(8.dp)) {
                            Text("⚠️ High priority will trigger a loud alarm sound on all devices!", modifier = Modifier.padding(8.dp), color = Color(0xFFEF4444), fontSize = 12.sp)
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (messageText.isNotBlank()) {
                            viewModel.sendGroupMessage(messageText.trim(), messagePriority)
                            Toast.makeText(context, "Message broadcast sent!", Toast.LENGTH_SHORT).show()
                            messageText = ""
                            messagePriority = "Medium"
                            showMessageDialog = false
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6366F1))
                ) { Text("Send") }
            },
            dismissButton = { TextButton(onClick = { showMessageDialog = false }) { Text("Cancel", color = textSecondary) } },
            containerColor = cardColor
        )
    }

    // Next Stop Dialog (creator only)
    if (showNextStopDialog) {
        AlertDialog(
            onDismissRequest = { showNextStopDialog = false },
            title = { Text("Set Next Stop", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Enter the next stop location. All members will receive a notification and can navigate via Google Maps.", color = textSecondary, fontSize = 13.sp)
                    OutlinedTextField(
                        value = nextStopInput, onValueChange = { nextStopInput = it },
                        label = { Text("Location name or address", color = textSecondary) },
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Color(0xFF3B82F6), unfocusedBorderColor = dividerColor, focusedTextColor = textPrimary, unfocusedTextColor = textPrimary)
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (nextStopInput.isNotBlank()) {
                            viewModel.updateNextStop(nextStopInput.trim())
                            Toast.makeText(context, "Next stop updated! All members notified.", Toast.LENGTH_SHORT).show()
                            nextStopInput = ""
                            showNextStopDialog = false
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF3B82F6))
                ) { Text("Set & Notify All") }
            },
            dismissButton = { TextButton(onClick = { showNextStopDialog = false }) { Text("Cancel", color = textSecondary) } },
            containerColor = cardColor
        )
    }

    // 2-Min Countdown Alarm Stop Dialog
    if (showAlarmDialog) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text("🚨 pull over now!", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = { Text("The 2-minute buffer for $activeTimerRequester's wait request has ended. Please stop safely.", color = textSecondary) },
            confirmButton = {
                Button(onClick = {
                    currentPlayingRingtone?.stop()
                    currentPlayingRingtone = null
                    showAlarmDialog = false
                }, colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444))) { Text("Acknowledge & Stop") }
            },
            containerColor = cardColor
        )
    }

    // SOS Confirmation
    if (showSOSConfirmation) {
        AlertDialog(
            onDismissRequest = { showSOSConfirmation = false },
            title = { Text("🚨 Send SOS Alert?", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = { Text("This will alert ALL group members with your location and trigger an alarm on their devices.", color = textSecondary) },
            confirmButton = {
                Button(onClick = { viewModel.triggerSOS(); showSOSConfirmation = false; Toast.makeText(context, "SOS Alert Sent!", Toast.LENGTH_LONG).show() },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFDC2626))
                ) { Text("SEND SOS") }
            },
            dismissButton = { TextButton(onClick = { showSOSConfirmation = false }) { Text("Cancel", color = textSecondary) } },
            containerColor = cardColor
        )
    }

    // Leave Group Confirmation
    if (showLeaveConfirmation) {
        AlertDialog(
            onDismissRequest = { showLeaveConfirmation = false },
            title = { Text("Leave Group?", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = { Text("You will stop sharing your location with the group.", color = textSecondary) },
            confirmButton = {
                Button(onClick = { viewModel.leaveGroup(); showLeaveConfirmation = false; onNavigateBack() },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444))
                ) { Text("Leave") }
            },
            dismissButton = { TextButton(onClick = { showLeaveConfirmation = false }) { Text("Stay", color = textPrimary) } },
            containerColor = cardColor
        )
    }

    // End Trip Confirmation (creator)
    if (showEndTripConfirmation) {
        AlertDialog(
            onDismissRequest = { showEndTripConfirmation = false },
            title = { Text("End Trip?", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = { Text("This will end the trip for ALL members and remove the group.", color = textSecondary) },
            confirmButton = {
                Button(onClick = { viewModel.endTrip { showEndTripConfirmation = false; onNavigateBack() } },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444))
                ) { Text("End Trip") }
            },
            dismissButton = { TextButton(onClick = { showEndTripConfirmation = false }) { Text("Cancel", color = textSecondary) } },
            containerColor = cardColor
        )
    }

    // Selected Member Details Dialog
    selectedMember?.let { member ->
        val isSelf = myLoc != null && member.userName == myLoc.userName
        AlertDialog(
            onDismissRequest = { selectedMember = null },
            title = { Text(member.userName, color = textPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("CONTACT DETAILS", color = Color(0xFF818CF8), fontWeight = FontWeight.Bold, fontSize = 11.sp)
                    if (member.phoneNumber.isNotBlank()) {
                        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth().clickable {
                            val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${member.phoneNumber}"))
                            context.startActivity(intent)
                        }) {
                            Text("Mobile Number:", color = textSecondary)
                            Text(member.phoneNumber, color = Color(0xFF10B981), fontWeight = FontWeight.Bold)
                        }
                    }
                    if (member.emergencyContactName.isNotBlank() || member.emergencyContact.isNotBlank()) {
                        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth().clickable {
                            if (member.emergencyContact.isNotBlank()) {
                                val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${member.emergencyContact}"))
                                context.startActivity(intent)
                            }
                        }) {
                            Text("Emergency Contact:", color = textSecondary)
                            val nameText = if (member.emergencyContactName.isNotBlank()) "${member.emergencyContactName} " else ""
                            Text("$nameText(${member.emergencyContact.ifBlank { "N/A" }})", color = Color(0xFFEF4444), fontWeight = FontWeight.Bold)
                        }
                    }

                    HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = 4.dp))
                    Text("VEHICLE INFORMATION", color = Color(0xFF818CF8), fontWeight = FontWeight.Bold, fontSize = 11.sp)
                    if (member.isCoRiding) {
                        Text("Co-riding with: ${member.ridingWithUserName.ifBlank { "Rider" }}", color = textPrimary, fontWeight = FontWeight.Bold)
                    } else if (member.vehicleType.isNotBlank() || member.vehicleNo.isNotBlank() || member.vehicleModel.isNotBlank()) {
                        if (member.vehicleType.isNotBlank()) Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) { Text("Type:", color = textSecondary); Text(member.vehicleType, color = textPrimary) }
                        if (member.vehicleModel.isNotBlank()) Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) { Text("Model:", color = textSecondary); Text(member.vehicleModel, color = textPrimary) }
                        if (member.vehicleNo.isNotBlank()) Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) { Text("Number:", color = textSecondary); Text(member.vehicleNo, color = textPrimary) }
                        if (member.vehicleColor.isNotBlank()) Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) { Text("Color:", color = textSecondary); Text(member.vehicleColor, color = textPrimary) }
                    } else {
                        Text("Not configured", color = textSecondary, fontSize = 13.sp)
                    }

                    HorizontalDivider(color = dividerColor, modifier = Modifier.padding(vertical = 4.dp))
                    Text("METRICS", color = Color(0xFF818CF8), fontWeight = FontWeight.Bold, fontSize = 11.sp)
                    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                        Text("Speed:", color = textSecondary); Text(if (member.isPaused) "Paused" else "${String.format("%.1f", member.speed)} km/h", color = textPrimary)
                    }
                    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                        Text("Battery:", color = textSecondary); Text("${member.battery}%", color = if (member.battery > 20) Color(0xFF10B981) else Color(0xFFEF4444))
                    }
                    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                        Text("Distance:", color = textSecondary)
                        val dist = if (!isSelf && myLoc != null && member.lat != 0.0 && member.lng != 0.0) calculateDistanceKm(member.lat, member.lng, myLoc.lat, myLoc.lng) else 0.0
                        Text(if (isSelf) "You (Current User)" else if (dist == 0.0) "Unknown" else if (dist < 1.0) String.format("%.0f m away", dist * 1000) else String.format("%.1f km away", dist), color = textPrimary, fontWeight = FontWeight.Bold)
                    }
                    if (member.ridingRole.isNotBlank()) {
                        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                            Text("Role:", color = textSecondary); Text(member.ridingRole, color = textPrimary)
                        }
                    }
                }
            },
            confirmButton = {
                val memberUserId = memberLocations.entries.firstOrNull { it.value == member }?.key
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (isGroupAdmin && memberUserId != null) {
                        Button(
                            onClick = {
                                showRoleDialogForMember = memberUserId to member.userName
                                selectedMember = null
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6366F1))
                        ) {
                            Text("Manage Role")
                        }
                    }
                    if (!isSelf && member.lat != 0.0 && member.lng != 0.0) {
                        Button(
                            onClick = {
                                val intent = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=${member.lat},${member.lng}"))
                                intent.setPackage("com.google.android.apps.maps")
                                try { context.startActivity(intent) } catch (e: Exception) {
                                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/maps?q=${member.lat},${member.lng}")))
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF3B82F6))
                        ) {
                            Icon(Icons.Default.Navigation, null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(4.dp))
                            Text("Open in Maps")
                        }
                    }
                }
            },
            dismissButton = { TextButton(onClick = { selectedMember = null }) { Text("Close", color = textSecondary) } },
            containerColor = cardColor
        )
    }

    showRoleDialogForMember?.let { (userId, userName) ->
        var selectedRole by remember { mutableStateOf("") }
        val currentRole = memberLocations[userId]?.ridingRole ?: "MIDDLE"
        
        AlertDialog(
            onDismissRequest = { showRoleDialogForMember = null },
            title = { Text("Change Riding Role", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Select role for $userName:", color = textSecondary)
                    listOf("LEAD", "MIDDLE", "SWEEP").forEach { role ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { selectedRole = role }
                                .padding(vertical = 8.dp)
                        ) {
                            RadioButton(
                                selected = (selectedRole == role || (selectedRole == "" && currentRole.uppercase() == role)),
                                onClick = { selectedRole = role },
                                colors = RadioButtonDefaults.colors(selectedColor = Color(0xFF818CF8))
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(role, color = textPrimary)
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val roleToSet = if (selectedRole != "") selectedRole else currentRole
                        viewModel.assignRidingRole(userId, roleToSet.uppercase())
                        showRoleDialogForMember = null
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6366F1))
                ) {
                    Text("Apply Role Change")
                }
            },
            dismissButton = {
                TextButton(onClick = { showRoleDialogForMember = null }) {
                    Text("Cancel", color = textSecondary)
                }
            },
            containerColor = cardColor
        )
    }

    if (showProfileDialogDashboard) {
        AlertDialog(
            onDismissRequest = { showProfileDialogDashboard = false },
            title = { Text("Safety Profile Registration", color = textPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(
                    modifier = Modifier.verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(
                        text = "To ensure group tracking, specify your Rider details. Vehicle Number is mandatory.",
                        color = textSecondary,
                        fontSize = 13.sp
                    )

                    OutlinedTextField(
                        value = profileName,
                        onValueChange = { profileName = it },
                        label = { Text("Your Display Name (Mandatory)", color = textSecondary) },
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
                        value = profilePhone,
                        onValueChange = { profilePhone = it },
                        label = { Text("Personal Mobile Number (Mandatory)", color = textSecondary) },
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
                        value = profileContact,
                        onValueChange = { profileContact = it },
                        label = { Text("Emergency Contact Number (Mandatory)", color = textSecondary) },
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
                        value = profileContactName,
                        onValueChange = { profileContactName = it },
                        label = { Text("Emergency Contact Name & Relationship (Mandatory)", color = textSecondary) },
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
                        value = profileType,
                        onValueChange = { profileType = it },
                        label = { Text("Vehicle Type (e.g., Bike, Car) (Mandatory)", color = textSecondary) },
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
                        label = { Text("Vehicle Number (Mandatory)", color = textSecondary) },
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
                        value = profileModel,
                        onValueChange = { profileModel = it },
                        label = { Text("Vehicle Model (e.g., Yamaha R15) (Mandatory)", color = textSecondary) },
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
                        label = { Text("Vehicle Color (Optional)", color = textSecondary) },
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
            },
            confirmButton = {
                val isValid = profileName.isNotBlank() && profilePhone.isNotBlank() &&
                        profileNo.isNotBlank() && profileContact.isNotBlank() &&
                        profileContactName.isNotBlank() && profileType.isNotBlank() &&
                        profileModel.isNotBlank()
                
                Button(
                    onClick = {
                        if (isValid) {
                            viewModel.saveUserDisplayName(profileName.trim())
                            viewModel.updateVehicleProfile(
                                vehicleType = profileType.trim(),
                                vehicleNo = profileNo.trim(),
                                vehicleColor = profileColor.trim(),
                                phoneNumber = profilePhone.trim(),
                                emergencyContact = profileContact.trim(),
                                isCoRiding = false,
                                ridingWithUserId = "",
                                ridingWithUserName = "",
                                vehicleModel = profileModel.trim(),
                                emergencyContactName = profileContactName.trim()
                            ) { success ->
                                if (success) {
                                    showProfileDialogDashboard = false
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
                TextButton(onClick = { showProfileDialogDashboard = false }) {
                    Text("Cancel", color = textSecondary)
                }
            },
            containerColor = cardColor
        )
    }
}

fun calculateDistanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val theta = lon1 - lon2
    var dist = Math.sin(Math.toRadians(lat1)) * Math.sin(Math.toRadians(lat2)) +
            Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) * Math.cos(Math.toRadians(theta))
    dist = Math.acos(dist)
    dist = Math.toDegrees(dist)
    dist = dist * 60 * 1.1515 * 1.609344
    return if (dist.isNaN()) 0.0 else dist
}

@Composable
fun RouteTimelineNode(
    title: String,
    address: String,
    isCompleted: Boolean,
    icon: ImageVector,
    iconColor: Color,
    textPrimary: Color,
    textSecondary: Color,
    cardColor: Color,
    dividerColor: Color,
    context: android.content.Context,
    onDelete: (() -> Unit)? = null
) {
    Card(
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = cardColor),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .background(iconColor.copy(alpha = 0.15f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(icon, contentDescription = null, tint = iconColor, modifier = Modifier.size(20.dp))
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, color = iconColor, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                Text(address, color = textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                IconButton(
                    onClick = {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" + Uri.encode(address)))
                        intent.setPackage("com.google.android.apps.maps")
                        try {
                            context.startActivity(intent)
                        } catch (e: Exception) {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/maps?q=" + Uri.encode(address))))
                        }
                    },
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(Icons.Default.Navigation, contentDescription = "Navigate", tint = Color(0xFF3B82F6), modifier = Modifier.size(18.dp))
                }
                if (onDelete != null) {
                    IconButton(
                        onClick = onDelete,
                        modifier = Modifier.size(32.dp)
                    ) {
                        Icon(Icons.Default.Delete, contentDescription = "Delete", tint = Color(0xFFEF4444), modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
    }
}
