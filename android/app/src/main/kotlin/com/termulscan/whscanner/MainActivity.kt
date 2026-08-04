package com.termulscan.whscanner

import android.content.Context
import android.location.LocationManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Semua plugin (geolocator, permission_handler, image_picker, mobile_scanner, dll.)
    // akan didaftarkan secara otomatis oleh Flutter Engine.
    //
    // Kanal manual:
    //  1. GNSS quality (satellite count + C/N0) — tidak diekspos geolocator,
    //     diambil langsung dari LocationManager via GnssStatus.Callback.
    //  2. Fused location bridge — dipakai menggantikan geolocator utk stream
    //     posisi di Android karena geolocator tidak mengekspos
    //     `setWaitForAccurateLocation(true)`. Lihat FusedLocationStreamHandler.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val locationManager =
            getSystemService(Context.LOCATION_SERVICE) as LocationManager

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GnssQualityStreamHandler.CHANNEL_NAME,
        ).setStreamHandler(GnssQualityStreamHandler(locationManager))

        val fusedHandler = FusedLocationStreamHandler(applicationContext)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FusedLocationStreamHandler.EVENT_CHANNEL,
        ).setStreamHandler(fusedHandler)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FusedLocationStreamHandler.METHOD_CHANNEL,
        ).setMethodCallHandler(fusedHandler::handleMethodCall)
    }
}
