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
            val mObj = org.json.JSONObject().apply {
                put("lat", loc.lat)
                put("lng", loc.lng)
                put("userName", loc.userName)
                put("speed", loc.speed.toDouble())
                put("ridingRole", loc.ridingRole)
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
        return jsonObj.toString().replace("'", "\\'")
    }

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
            loadDataWithBaseURL("https://openstreetmap.org", getLeafletHtml(), "text/html", "UTF-8", null)
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

private fun getLeafletHtml(): String {
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
            </style>
        </head>
        <body>
            <div id="map"></div>
            <script>
                var map = L.map('map').setView([15.4909, 73.8278], 14);
                
                L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                    maxZoom: 19,
                    attribution: '© OpenStreetMap'
                }).addTo(map);

                var markers = {};
                var polylines = {};

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
                            markers[id].setLatLng(latlng);
                        } else {
                            var marker = L.marker(latlng).addTo(map);
                            marker.on('click', (function(mName) {
                                return function() {
                                    Android.onMarkerClicked(mName);
                                }
                            })(loc.userName));
                            markers[id] = marker;
                        }

                        markers[id].bindTooltip(loc.userName + " (" + (loc.ridingRole || "Rider") + ")<br>Speed: " + loc.speed.toFixed(1) + " km/h", { permanent: false, direction: 'top' });

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
