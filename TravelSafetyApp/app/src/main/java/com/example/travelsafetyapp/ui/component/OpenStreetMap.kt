package com.example.travelsafetyapp.ui.component

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.example.travelsafetyapp.domain.model.Group
import com.example.travelsafetyapp.domain.model.MemberLocation

@Composable
fun OpenStreetMap(
    memberLocations: Map<String, MemberLocation>,
    myLoc: MemberLocation?,
    activeSosUserIds: Set<String> = emptySet(),
    activeGroup: Group? = null,
    onMarkerClick: (MemberLocation) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current

    // Geocoded route coordinates states
    var startCoords by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var destCoords by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var stopCoordsList by remember { mutableStateOf<List<Pair<Double, Double>>>(emptyList()) }
    var isMapReady by remember { mutableStateOf(false) }

    // Geocode group route destinations on change
    LaunchedEffect(activeGroup?.startPoint, activeGroup?.destination, activeGroup?.stopPoints) {
        val group = activeGroup ?: return@LaunchedEffect
        
        // Geocode startPoint
        if (group.startPoint.isNotBlank()) {
            try {
                val places = com.example.travelsafetyapp.data.client.NominatimClient.searchAddress(group.startPoint)
                val first = places.firstOrNull()
                startCoords = first?.lat?.toDoubleOrNull()?.let { lat ->
                    first.lon.toDoubleOrNull()?.let { lon -> lat to lon }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        } else {
            startCoords = null
        }

        // Geocode destination
        if (group.destination.isNotBlank()) {
            try {
                val places = com.example.travelsafetyapp.data.client.NominatimClient.searchAddress(group.destination)
                val first = places.firstOrNull()
                destCoords = first?.lat?.toDoubleOrNull()?.let { lat ->
                    first.lon.toDoubleOrNull()?.let { lon -> lat to lon }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        } else {
            destCoords = null
        }

        // Geocode stopPoints
        val resolvedStops = mutableListOf<Pair<Double, Double>>()
        group.stopPoints.forEach { stop ->
            if (stop.isNotBlank()) {
                try {
                    val places = com.example.travelsafetyapp.data.client.NominatimClient.searchAddress(stop)
                    val first = places.firstOrNull()
                    val lat = first?.lat?.toDoubleOrNull()
                    val lon = first?.lon?.toDoubleOrNull()
                    if (lat != null && lon != null) {
                        resolvedStops.add(lat to lon)
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
        stopCoordsList = resolvedStops
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

    fun serializeLocationsToJson(): String {
        val jsonObj = org.json.JSONObject()
        val leadLoc = memberLocations.values.firstOrNull { it.ridingRole.uppercase() == "LEAD" }
        
        memberLocations.forEach { (id, loc) ->
            if (loc.tripState == "STARTED") { // Only show members with tripState == STARTED
                val mObj = org.json.JSONObject().apply {
                    put("lat", loc.lat)
                    put("lng", loc.lng)
                    put("userName", loc.userName)
                    put("speed", loc.speed.toDouble())
                    put("ridingRole", loc.ridingRole)
                    put("isPaused", loc.isPaused)
                    put("isSosActive", activeSosUserIds.contains(id))
                    
                    var dist = 0.0
                    var isFallingBehind = false
                    if (leadLoc != null && leadLoc != loc && loc.lat != 0.0 && loc.lng != 0.0 && leadLoc.lat != 0.0 && leadLoc.lng != 0.0) {
                        dist = calculateDistanceKm(loc.lat, loc.lng, leadLoc.lat, leadLoc.lng)
                        if (dist > 1.0) {
                            isFallingBehind = true
                        }
                    }
                    put("distanceToLead", dist)
                    put("isFallingBehind", isFallingBehind)
                    
                    put("routeHistory", org.json.JSONObject().apply {
                        loc.routeHistory.forEach { (hid, pt) ->
                            put(hid, org.json.JSONObject().apply {
                                put("lat", pt.lat)
                                put("lng", pt.lng)
                            })
                        }
                    })
                }
                jsonObj.put(id, mObj)
            }
        }
        return jsonObj.toString().replace("'", "\\'")
    }

    fun serializeRouteJson(): String {
        val jsonObj = org.json.JSONObject()
        startCoords?.let {
            jsonObj.put("startPoint", org.json.JSONObject().apply {
                put("lat", it.first)
                put("lng", it.second)
                put("label", activeGroup?.startPoint ?: "Start")
            })
        }
        destCoords?.let {
            jsonObj.put("destination", org.json.JSONObject().apply {
                put("lat", it.first)
                put("lng", it.second)
                put("label", activeGroup?.destination ?: "Destination")
            })
        }
        val stopsArr = org.json.JSONArray()
        stopCoordsList.forEachIndexed { index, s ->
            stopsArr.put(org.json.JSONObject().apply {
                put("lat", s.first)
                put("lng", s.second)
                put("label", activeGroup?.stopPoints?.getOrNull(index) ?: "Stop ${index + 1}")
            })
        }
        jsonObj.put("stopPoints", stopsArr)
        return jsonObj.toString().replace("'", "\\'")
    }

    val initialLat = myLoc?.lat ?: 15.4909
    val initialLng = myLoc?.lng ?: 73.8278

    val webView = remember {
        WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.databaseEnabled = true
            settings.userAgentString = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36 CoRouteTravelSafetyApp/1.0"
            
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            }
            
            webChromeClient = object : android.webkit.WebChromeClient() {
                override fun onConsoleMessage(consoleMessage: android.webkit.ConsoleMessage?): Boolean {
                    android.util.Log.e("WebViewConsole", "${consoleMessage?.messageLevel()}: ${consoleMessage?.message()} -- From line ${consoleMessage?.lineNumber()} of ${consoleMessage?.sourceId()}")
                    return true
                }
            }
            
            addJavascriptInterface(object {
                @android.webkit.JavascriptInterface
                fun onMarkerClicked(userName: String) {
                    val clickedLoc = memberLocations.values.firstOrNull { it.userName == userName }
                    if (clickedLoc != null) {
                        onMarkerClick(clickedLoc)
                    }
                }

                @android.webkit.JavascriptInterface
                fun onMapReady() {
                    post {
                        isMapReady = true
                        val js = "javascript:updateLocations('${serializeLocationsToJson()}', '${serializeRouteJson()}')"
                        evaluateJavascript(js, null)
                    }
                }
            }, "Android")

            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) {
                    val checkJs = """
                        if (typeof updateLocations === 'function') {
                            Android.onMapReady();
                        }
                    """.trimIndent()
                    view?.evaluateJavascript(checkJs, null)
                }
            }
            loadDataWithBaseURL(null, getLeafletHtml(initialLat, initialLng), "text/html", "UTF-8", null)
        }
    }

    LaunchedEffect(memberLocations, activeSosUserIds, startCoords, destCoords, stopCoordsList, isMapReady) {
        if (isMapReady) {
            val js = "javascript:updateLocations('${serializeLocationsToJson()}', '${serializeRouteJson()}')"
            webView.evaluateJavascript(js, null)
        }
    }

    AndroidView(
        factory = { webView },
        modifier = modifier
    )
}

private fun getLeafletHtml(startLat: Double, startLng: Double): String {
    return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
            <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
            <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
            <style>
                body { margin: 0; padding: 0; }
                #map { height: 100vh; width: 100vw; background: #0f172a; }
                #offline-banner {
                    position: absolute;
                    top: 10px;
                    left: 50%;
                    transform: translateX(-50%);
                    background: rgba(15, 23, 42, 0.9);
                    color: #f1f5f9;
                    padding: 8px 16px;
                    border-radius: 20px;
                    font-family: sans-serif;
                    font-size: 12px;
                    z-index: 1000;
                    display: none;
                    box-shadow: 0 2px 8px rgba(0,0,0,0.5);
                }
                @keyframes pulse-red {
                    0% { opacity: 1.0; }
                    50% { opacity: 0.3; }
                    100% { opacity: 1.0; }
                }
                .blinking-marker {
                    animation: pulse-red 1s infinite;
                }
            </style>
        </head>
        <body>
            <div id="offline-banner">Loading map tiles...</div>
            <div id="map"></div>
            <script>
                var map = L.map('map').setView([$startLat, $startLng], 14);
                setTimeout(function() { map.invalidateSize(); }, 200);
                
                var tiles = L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
                    maxZoom: 19,
                    attribution: '© OpenStreetMap contributors'
                }).addTo(map);

                var banner = document.getElementById('offline-banner');
                var redrawTimeout = null;

                tiles.on('loading', function() {
                    banner.style.display = 'block';
                    banner.innerHTML = 'Loading map tiles...';
                });

                tiles.on('load', function() {
                    banner.style.display = 'none';
                });

                tiles.on('tileerror', function() {
                    banner.style.display = 'block';
                    banner.innerHTML = '⚠️ Map offline. Retrying...';
                    if (!redrawTimeout) {
                        redrawTimeout = setTimeout(function() {
                            tiles.redraw();
                            redrawTimeout = null;
                        }, 5000);
                    }
                });

                var markers = {};
                var polylines = {};
                var previousCoords = {};

                var routeMarkers = [];
                var routeLine = null;

                function calculateBearing(lat1, lng1, lat2, lng2) {
                    var dLon = (lng2 - lng1) * Math.PI / 180;
                    var lat1Rad = lat1 * Math.PI / 180;
                    var lat2Rad = lat2 * Math.PI / 180;
                    var y = Math.sin(dLon) * Math.cos(lat2Rad);
                    var x = Math.cos(lat1Rad) * Math.sin(lat2Rad) - Math.sin(lat1Rad) * Math.cos(lat2Rad) * Math.cos(dLon);
                    var bearing = Math.atan2(y, x) * 180 / Math.PI;
                    return (bearing + 360) % 360;
                }

                function getRouteIcon(type) {
                    var color = '#10b981'; // Green for Start
                    if (type === 'destination') color = '#ef4444'; // Red for Dest
                    else if (type === 'stop') color = '#f59e0b'; // Orange for Stops
                    
                    var svg = '<svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">' +
                        '<path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z" fill="' + color + '" stroke="white" stroke-width="1.5"/>' +
                        '</svg>';
                    return L.icon({
                        iconUrl: 'data:image/svg+xml;base64,' + btoa(svg),
                        iconSize: [24, 24],
                        iconAnchor: [12, 24],
                        popupAnchor: [0, -24],
                        tooltipAnchor: [0, -24]
                    });
                }

                function getMarkerIcon(ridingRole, isPaused, bearing, isFallingBehind, isSosActive) {
                    var color = '#818cf8'; // default MIDDLE (indigo)
                    var roleUpper = (ridingRole || '').toUpperCase();
                    if (roleUpper === 'LEAD') color = '#ef4444'; // LEAD is Red
                    else if (roleUpper === 'SWEEP') color = '#10b981'; // SWEEP is Green
                    if (isPaused) color = '#f59e0b'; // PAUSED is Orange
                    
                    if (isFallingBehind || isSosActive) color = '#ef4444'; // Red blinking for falling behind / SOS

                    var arrowSvg = '';
                    if (bearing !== null && bearing !== undefined) {
                        arrowSvg = '<path d="M12 2L16 8H8L12 2Z" fill="#ffffff" transform="rotate(' + bearing + ' 12 12) translate(0 -10)"/>';
                    }

                    var shapeSvg = '';
                    if (roleUpper === 'LEAD') {
                        shapeSvg = '<polygon points="12,2 15,9 22,9 17,14 19,21 12,17 5,21 7,14 2,9 9,9" fill="' + color + '" stroke="white" stroke-width="1.5"/>';
                    } else if (roleUpper === 'SWEEP') {
                        shapeSvg = '<polygon points="12,2 22,12 12,22 2,12" fill="' + color + '" stroke="white" stroke-width="1.5"/>';
                    } else {
                        shapeSvg = '<path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z" fill="' + color + '" stroke="white" stroke-width="1.5"/>';
                    }

                    var svg = '<svg width="30" height="30" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">' +
                        shapeSvg +
                        arrowSvg +
                        '</svg>';
                    return L.icon({
                        iconUrl: 'data:image/svg+xml;base64,' + btoa(svg),
                        iconSize: [30, 30],
                        iconAnchor: [15, 30],
                        popupAnchor: [0, -30],
                        tooltipAnchor: [0, -30],
                        className: (isFallingBehind || isSosActive) ? 'blinking-marker' : ''
                    });
                }

                function animateMarkerTo(marker, endLatLng, durationMs) {
                    if (marker.animFrame) {
                        cancelAnimationFrame(marker.animFrame);
                    }
                    var startLatLng = marker.getLatLng();
                    var startTime = performance.now();
                    
                    function tick(now) {
                        var elapsed = now - startTime;
                        var progress = Math.min(elapsed / durationMs, 1);
                        
                        var lat = startLatLng.lat + (endLatLng[0] - startLatLng.lat) * progress;
                        var lng = startLatLng.lng + (endLatLng[1] - startLatLng.lng) * progress;
                        
                        marker.setLatLng([lat, lng]);
                        
                        if (progress < 1) {
                            marker.animFrame = requestAnimationFrame(tick);
                        } else {
                            marker.animFrame = null;
                        }
                    }
                    marker.animFrame = requestAnimationFrame(tick);
                }

                function updateLocations(locationsJson, routeJson) {
                    map.invalidateSize();
                    var data = JSON.parse(locationsJson);
                    var bounds = [];

                    // Remove old markers
                    for (var id in markers) {
                        if (!data[id]) {
                            map.removeLayer(markers[id]);
                            delete markers[id];
                            delete previousCoords[id];
                        }
                    }
                    // Remove old polylines
                    for (var id in polylines) {
                        if (!data[id]) {
                            map.removeLayer(polylines[id]);
                            delete polylines[id];
                        }
                    }

                    // Render Route Visualization
                    if (routeJson) {
                        var routeData = JSON.parse(routeJson);
                        
                        // Clear old route layers
                        routeMarkers.forEach(function(m) { map.removeLayer(m); });
                        routeMarkers = [];
                        if (routeLine) {
                            map.removeLayer(routeLine);
                            routeLine = null;
                        }

                        var routeLatLngs = [];

                        if (routeData.startPoint) {
                            var startLatLng = [routeData.startPoint.lat, routeData.startPoint.lng];
                            routeLatLngs.push(startLatLng);
                            bounds.push(startLatLng);
                            var m = L.marker(startLatLng, { icon: getRouteIcon('start') }).addTo(map);
                            m.bindTooltip("Start: " + routeData.startPoint.label, { permanent: false, direction: 'top' });
                            routeMarkers.push(m);
                        }

                        if (routeData.stopPoints) {
                            routeData.stopPoints.forEach(function(stop) {
                                var stopLatLng = [stop.lat, stop.lng];
                                routeLatLngs.push(stopLatLng);
                                bounds.push(stopLatLng);
                                var m = L.marker(stopLatLng, { icon: getRouteIcon('stop') }).addTo(map);
                                m.bindTooltip("Stop: " + stop.label, { permanent: false, direction: 'top' });
                                routeMarkers.push(m);
                            });
                        }

                        if (routeData.destination) {
                            var destLatLng = [routeData.destination.lat, routeData.destination.lng];
                            routeLatLngs.push(destLatLng);
                            bounds.push(destLatLng);
                            var m = L.marker(destLatLng, { icon: getRouteIcon('destination') }).addTo(map);
                            m.bindTooltip("Destination: " + routeData.destination.label, { permanent: false, direction: 'top' });
                            routeMarkers.push(m);
                        }

                        if (routeLatLngs.length >= 2) {
                            routeLine = L.polyline(routeLatLngs, {
                                color: '#3b82f6',
                                weight: 5,
                                opacity: 0.7,
                                dashArray: '8, 12'
                            }).addTo(map);
                        }
                    }

                    // Render Rider Locations
                    for (var id in data) {
                        var loc = data[id];
                        if (loc.lat === 0.0 && loc.lng === 0.0) continue;
                        
                        var latlng = [loc.lat, loc.lng];
                        bounds.push(latlng);

                        // Calculate bearing
                        var bearing = null;
                        if (previousCoords[id] && (previousCoords[id].lat !== loc.lat || previousCoords[id].lng !== loc.lng)) {
                            bearing = calculateBearing(previousCoords[id].lat, previousCoords[id].lng, loc.lat, loc.lng);
                            if (markers[id]) markers[id].bearing = bearing;
                        } else if (markers[id] && markers[id].bearing !== undefined) {
                            bearing = markers[id].bearing;
                        }
                        previousCoords[id] = { lat: loc.lat, lng: loc.lng };

                        var icon = getMarkerIcon(loc.ridingRole, loc.isPaused, bearing, loc.isFallingBehind, loc.isSosActive);

                        if (markers[id]) {
                            markers[id].setIcon(icon);
                            animateMarkerTo(markers[id], latlng, 1000);
                        } else {
                            var marker = L.marker(latlng, { icon: icon }).addTo(map);
                            marker.bearing = bearing;
                            marker.on('click', (function(mName) {
                                return function() {
                                    Android.onMarkerClicked(mName);
                                }
                            })(loc.userName));
                            markers[id] = marker;
                        }

                        var distLabel = "";
                        if (loc.distanceToLead > 0) {
                            distLabel = "<br>Distance to Lead: " + loc.distanceToLead.toFixed(2) + " km";
                        }
                        var tooltipContent = loc.userName + " (" + (loc.ridingRole || "Rider") + ")<br>Speed: " + loc.speed.toFixed(1) + " km/h" + distLabel;
                        if (markers[id].getTooltip()) {
                            markers[id].setTooltipContent(tooltipContent);
                        } else {
                            markers[id].bindTooltip(tooltipContent, { permanent: false, direction: 'top' });
                        }

                        // Draw path polyline for routeHistory
                        var routePoints = [];
                        if (loc.routeHistory) {
                            for (var key in loc.routeHistory) {
                                routePoints.push([loc.routeHistory[key].lat, loc.routeHistory[key].lng]);
                            }
                        }
                        if (routePoints.length >= 2) {
                            if (polylines[id]) {
                                polylines[id].setLatLngs(routePoints);
                            } else {
                                var color = '#818cf8';
                                if (loc.ridingRole === 'Lead') color = '#ef4444';
                                else if (loc.ridingRole === 'Middle') color = '#3b82f6';
                                else if (loc.ridingRole === 'Sweep') color = '#10b981';

                                polylines[id] = L.polyline(routePoints, {color: color, weight: 4}).addTo(map);
                            }
                        }
                    }

                    if (bounds.length > 0) {
                        map.fitBounds(bounds, { padding: [50, 50], maxZoom: 15 });
                    }
                }

                function checkAndroidReady() {
                    if (window.Android && typeof window.Android.onMapReady === 'function') {
                        window.Android.onMapReady();
                    } else {
                        setTimeout(checkAndroidReady, 100);
                    }
                }
                checkAndroidReady();
            </script>
        </body>
        </html>
    """.trimIndent()
}
