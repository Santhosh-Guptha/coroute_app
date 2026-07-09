package com.example.travelsafetyapp.data.client

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

data class NominatimPlace(
    val display_name: String = "",
    val lat: String = "0.0",
    val lon: String = "0.0"
)

object NominatimClient {

    private fun decodeUnicode(input: String): String {
        val regex = Regex("\\\\u([0-9a-fA-F]{4})")
        return regex.replace(input) { matchResult ->
            try {
                val hex = matchResult.groupValues[1]
                hex.toInt(16).toChar().toString()
            } catch (e: Exception) {
                matchResult.value
            }
        }
    }

    suspend fun searchAddress(query: String): List<NominatimPlace> = withContext(Dispatchers.IO) {
        if (query.trim().length < 3) return@withContext emptyList()
        var connection: HttpURLConnection? = null
        try {
            val encodedQuery = URLEncoder.encode(query.trim(), "UTF-8")
            val url = URL("https://nominatim.openstreetmap.org/search?q=$encodedQuery&format=json&limit=5&addressdetails=1")
            connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.setRequestProperty("User-Agent", "CoRouteTravelSafetyApp/1.0")
            connection.connectTimeout = 8000
            connection.readTimeout = 8000

            if (connection.responseCode == 200) {
                val responseText = connection.inputStream.bufferedReader().use { it.readText() }
                
                // Parse manually to avoid kotlinx.serialization.json dependency mismatch
                val list = mutableListOf<NominatimPlace>()
                
                // Regex matches display_name, latitude and longitude
                val displayRegex = Regex("\"display_name\"\\s*:\\s*\"([^\"]+)\"")
                val latRegex = Regex("\"lat\"\\s*:\\s*\"([^\"]+)\"")
                val lonRegex = Regex("\"lon\"\\s*:\\s*\"([^\"]+)\"")
                
                val displays = displayRegex.findAll(responseText).map { decodeUnicode(it.groupValues[1]) }.toList()
                val lats = latRegex.findAll(responseText).map { it.groupValues[1] }.toList()
                val lons = lonRegex.findAll(responseText).map { it.groupValues[1] }.toList()
                
                for (i in displays.indices) {
                    val name = displays[i]
                    val lat = lats.getOrNull(i) ?: "0.0"
                    val lon = lons.getOrNull(i) ?: "0.0"
                    list.add(NominatimPlace(display_name = name, lat = lat, lon = lon))
                }
                
                list
            } else {
                emptyList()
            }
        } catch (e: Exception) {
            e.printStackTrace()
            emptyList()
        } finally {
            connection?.disconnect()
        }
    }
}
