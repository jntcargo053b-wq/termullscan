package com.termulscan.app

import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.termulscan.app/location"
    private lateinit var locationManager: LocationManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getLocation") getCurrentLocation(result) else result.notImplemented()
        }
    }

    private fun getCurrentLocation(result: MethodChannel.Result) {
        val hasPermission =
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

        if (!hasPermission) {
            result.error("PERMISSION_DENIED", "Location permission not granted", null)
            return
        }

        val last = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
            ?: locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)

        if (last != null) {
            result.success(mapOf("lat" to last.latitude, "lng" to last.longitude, "accuracy" to last.accuracy))
            return
        }

        val sent = AtomicBoolean(false)
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        lateinit var listener: LocationListener

        fun finishWith(location: Location?) {
            if (!sent.compareAndSet(false, true)) return
            try { locationManager.removeUpdates(listener) } catch (_: Exception) {}
            result.success(mapOf(
                "lat" to location?.latitude,
                "lng" to location?.longitude,
                "accuracy" to location?.accuracy
            ))
        }

        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) = finishWith(location)
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }

        var requested = false
        providers.forEach { provider ->
            if (locationManager.isProviderEnabled(provider)) {
                try {
                    locationManager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
                    requested = true
                } catch (_: Exception) {}
            }
        }

        if (!requested) {
            result.error("NO_PROVIDER", "No location provider enabled", null)
            return
        }

        Handler(Looper.getMainLooper()).postDelayed({ finishWith(null) }, 5000)
    }
}
