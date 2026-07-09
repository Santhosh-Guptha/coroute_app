package com.example.travelsafetyapp.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.PopupProperties
import com.example.travelsafetyapp.data.client.NominatimClient
import com.example.travelsafetyapp.data.client.NominatimPlace
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LocationAutoCompleteTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    leadingIcon: @Composable (() -> Unit)?,
    textPrimary: Color,
    textSecondary: Color,
    cardColor: Color,
    dividerColor: Color,
    modifier: Modifier = Modifier
) {
    var query by remember { mutableStateOf(value) }
    var suggestions by remember { mutableStateOf<List<NominatimPlace>>(emptyList()) }
    var isSearching by remember { mutableStateOf(false) }

    LaunchedEffect(value) {
        if (value != query) {
            query = value
        }
    }

    LaunchedEffect(query) {
        if (query.trim().length >= 3 && query != value) {
            delay(500) // Debounce wait
            isSearching = true
            suggestions = NominatimClient.searchAddress(query)
            isSearching = false
        } else if (query.trim().length < 3) {
            suggestions = emptyList()
        }
    }

    Box(modifier = modifier.fillMaxWidth()) {
        Column(modifier = Modifier.fillMaxWidth()) {
            OutlinedTextField(
                value = query,
                onValueChange = {
                    query = it
                    if (it.isBlank()) {
                        onValueChange("")
                    }
                },
                label = { Text(label, color = textSecondary) },
                leadingIcon = leadingIcon,
                trailingIcon = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (isSearching) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = Color(0xFF818CF8)
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                        }
                        if (query.isNotEmpty()) {
                            IconButton(onClick = {
                                query = ""
                                onValueChange("")
                                suggestions = emptyList()
                            }) {
                                Icon(Icons.Default.Clear, contentDescription = "Clear text", tint = textSecondary)
                            }
                        }
                    }
                },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color(0xFF818CF8),
                    unfocusedBorderColor = dividerColor,
                    focusedTextColor = textPrimary,
                    unfocusedTextColor = textPrimary
                ),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            DropdownMenu(
                expanded = suggestions.isNotEmpty(),
                onDismissRequest = { suggestions = emptyList() },
                modifier = Modifier
                    .fillMaxWidth(0.85f)
                    .background(cardColor),
                properties = PopupProperties(focusable = false)
            ) {
                suggestions.forEach { place ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = place.display_name,
                                color = textPrimary,
                                fontSize = 13.sp,
                                maxLines = 2
                            )
                        },
                        onClick = {
                            onValueChange(place.display_name)
                            query = place.display_name
                            suggestions = emptyList()
                        }
                    )
                }
            }
        }
    }
}
