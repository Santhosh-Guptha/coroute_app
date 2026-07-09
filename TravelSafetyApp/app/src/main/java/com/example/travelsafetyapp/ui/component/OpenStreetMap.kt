package com.example.travelsafetyapp.ui.component

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.example.travelsafetyapp.domain.model.MemberLocation

@Composable
fun OpenStreetMap(
    memberLocations: Map<String, MemberLocation>,
    myLoc: MemberLocation?,
    onMarkerClick: (MemberLocation) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    
    fun serializeLocationsToJson(): String {
        val jsonObj = org.json.JSONObject()
        memberLocations.forEach { (id, loc) ->
            if (loc.tripState == "STARTED") { // Only show members with tripState == STARTED
                val mObj = org.json.JSONObject().apply {
                    put("lat", loc.lat)
                    put("lng", loc.lng)
                    put("userName", loc.userName)
                    put("speed", loc.speed.toDouble())
                    put("ridingRole", loc.ridingRole)
                    put("isPaused", loc.isPaused)
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

    val initialLat = myLoc?.lat ?: 15.4909
    val initialLng = myLoc?.lng ?: 73.8278

    val webView = remember {
        WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            
            addJavascriptInterface(object {
                @android.webkit.JavascriptInterface
                fun onMarkerClicked(userName: String) {
                    val clickedLoc = memberLocations.values.firstOrNull { it.userName == userName }
                    if (clickedLoc != null) {
                        onMarkerClick(clickedLoc)
                    }
                }
            }, "Android")

            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) {
                    val js = "javascript:updateLocations('${serializeLocationsToJson()}')"
                    view?.evaluateJavascript(js, null)
                }
            }
            loadDataWithBaseURL("https://openstreetmap.org", getLeafletHtml(initialLat, initialLng), "text/html", "UTF-8", null)
        }
    }

    LaunchedEffect(memberLocations) {
        val js = "javascript:updateLocations('${serializeLocationsToJson()}')"
        webView.evaluateJavascript(js, null)
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
            </style>
        </head>
        <body>
            <div id="offline-banner">Loading map tiles...</div>
            <div id="map"></div>
            <script>
                var map = L.map('map').setView([$startLat, $startLng], 14);
                
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

                function getMarkerIcon(ridingRole, isPaused) {
                    var color = '#818cf8'; // default
                    if (ridingRole === 'Lead') color = '#ef4444';
                    else if (ridingRole === 'Sweep') color = '#10b981';
                    if (isPaused) color = '#f59e0b';

                    var svg = '<svg width="30" height="30" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">' +
                        '<path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z" fill="' + color + '" stroke="white" stroke-width="1.5"/>' +
                        '</svg>';
                    return L.icon({
                        iconUrl: 'data:image/svg+xml;base64,' + btoa(svg),
                        iconSize: [30, 30],
                        iconAnchor: [15, 30],
                        popupAnchor: [0, -30],
                        tooltipAnchor: [0, -30]
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

                function updateLocations(locationsJson) {
                    var data = JSON.parse(locationsJson);
                    
                    // Remove old markers
                    for (var id in markers) {
                        if (!data[id]) {
                            map.removeLayer(markers[id]);
                            delete markers[id];
                        }
                    }
                    // Remove old polylines
                    for (var id in polylines) {
                        if (!data[id]) {
                            map.removeLayer(polylines[id]);
                            delete polylines[id];
                        }
                    }

                    var bounds = [];

                    for (var id in data) {
                        var loc = data[id];
                        if (loc.lat === 0.0 && loc.lng === 0.0) continue;
                        
                        var latlng = [loc.lat, loc.lng];
                        bounds.push(latlng);

                        if (markers[id]) {
                            markers[id].setIcon(getMarkerIcon(loc.ridingRole, loc.isPaused));
                            animateMarkerTo(markers[id], latlng, 1000);
                        } else {
                            var marker = L.marker(latlng, { icon: getMarkerIcon(loc.ridingRole, loc.isPaused) }).addTo(map);
                            marker.on('click', (function(mName) {
                                return function() {
                                    Android.onMarkerClicked(mName);
                                }
                            })(loc.userName));
                            markers[id] = marker;
                        }

                        var tooltipContent = loc.userName + " (" + (loc.ridingRole || "Rider") + ")<br>Speed: " + loc.speed.toFixed(1) + " km/h";
                        if (markers[id].getTooltip()) {
                            markers[id].setTooltipContent(tooltipContent);
                        } else {
                            markers[id].bindTooltip(tooltipContent, { permanent: false, direction: 'top' });
                        }

                        // Draw path polyline
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
            </script>
        </body>
        </html>
    """.trimIndent()
}
