package com.termulscan.whscanner

import android.content.Context
import android.location.LocationManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    // Semua plugin (geolocator, permission_handler, image_picker, mobile_scanner, dll.)
    // akan didaftarkan secara otomatis oleh Flutter Engine.
    //
    // Satu-satunya kanal manual: GNSS quality (satellite count + C/N0),
    // karena data ini tidak diekspos oleh package geolocator dan harus
    // diambil langsung dari LocationManager via GnssStatus.Callback.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val locationManager =
            getSystemService(Context.LOCATION_SERVICE) as LocationManager

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GnssQualityStreamHandler.CHANNEL_NAME,
        ).setStreamHandler(GnssQualityStreamHandler(locationManager))
    }
}
