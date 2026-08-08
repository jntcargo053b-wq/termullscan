package com.termulscan.whscanner

// ============================================================
// FUSED LOCATION STREAM HANDLER
// ============================================================
// Menjembatani FusedLocationProviderClient langsung (bukan lewat
// package geolocator) karena geolocator TIDAK mengekspos
// `setWaitForAccurateLocation`, opsi yang dulu dipakai di sini
// (true) untuk menahan callback pertama sampai FLP anggap fix-nya
// cukup akurat.
//
// ⚡ BARU: diubah ke `false`. `waitForAccurateLocation(true)` justru
// KONTRAPRODUKTIF terhadap tujuan lock cepat — di kondisi yang paling
// butuh cepat (indoor/gudang), FLP bisa menahan callback pertama
// berdetik-detik sebelum anggap fix "cukup akurat", padahal
// PodGpsEngine di sisi Dart SUDAH punya mekanisme lengkap untuk
// menyaring fix kasar sendiri: gate admisi accuracy adaptif
// (outdoorAccuracyThreshold=25m/indoorAccuracyThreshold=40m — fix
// network/cell-based yang biasanya >100m otomatis tertolak di sana),
// MAD-based outlier rejection, dan convergence lock untuk tier
// "excellent". Menahan di level native cuma menambah latency tanpa
// manfaat presisi tambahan, karena penyaringan sudah terjadi di
// hilir. Pola Google Maps/blue-dot juga selalu tampilkan estimasi
// awal secepatnya lalu refine belakangan — bukan menunda tampilan
// sampai "akurat".
//
// EVENT_CHANNEL  : stream posisi kontinu. Listen = mulai
//                  requestLocationUpdates (GPS chip aktif = warm-up).
//                  Cancel = stop (baterai nol saat idle). Pola sama
//                  seperti GnssQualityStreamHandler yang sudah ada.
// METHOD_CHANNEL : getLastLocation() — snapshot instan dari cache
//                  FusedLocationProviderClient, biasanya lebih segar
//                  dari Geolocator.getLastKnownPosition() karena
//                  fused cache digabung dari semua app yang minta
//                  lokasi di device, bukan cuma app ini.
//
// Tidak menangani permission — sisi Dart (PodLocationService) sudah
// punya alur permission check sebelum memulai stream/method call ini.
// SecurityException di sini berarti caller lupa cek izin dulu.
// ============================================================

import android.annotation.SuppressLint
import android.content.Context
import android.os.Looper
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationAvailability
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FusedLocationStreamHandler(
    context: Context,
) : EventChannel.StreamHandler {

    companion object {
        const val EVENT_CHANNEL = "com.termulscan.whscanner/fused_location"
        const val METHOD_CHANNEL = "com.termulscan.whscanner/fused_location_control"

        // Target interval 1Hz (standar chip GPS konsumen), tapi
        // minUpdateInterval dilonggarkan ke 500ms supaya update lebih
        // cepat dari fusion sensor lain tidak dibuang percuma oleh
        // throttle internal FusedLocationProviderClient.
        private const val INTERVAL_MS = 1000L
        private const val MIN_UPDATE_INTERVAL_MS = 500L
    }

    private val client: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(context)

    private var callback: LocationCallback? = null
    private var sink: EventChannel.EventSink? = null

    @SuppressLint("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        if (events == null) return
        sink = events

        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, INTERVAL_MS)
            .setMinUpdateIntervalMillis(MIN_UPDATE_INTERVAL_MS)
            // ⚡ BARU: false — jangan tahan callback pertama. Fix kasar
            // (kalau memang terjadi) sudah tersaring di PodGpsEngine
            // (gate accuracy adaptif + outlier rejection + convergence).
            // Lihat catatan panjang di header file.
            .setWaitForAccurateLocation(false)
            .build()

        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val loc = result.lastLocation ?: return
                val payload = mapOf(
                    "latitude" to loc.latitude,
                    "longitude" to loc.longitude,
                    "accuracy" to loc.accuracy.toDouble(),
                    "altitude" to if (loc.hasAltitude()) loc.altitude else null,
                    "speed" to if (loc.hasSpeed()) loc.speed.toDouble() else null,
                    "speedAccuracy" to
                        if (loc.hasSpeedAccuracy()) loc.speedAccuracyMetersPerSecond.toDouble() else 0.0,
                    "bearing" to if (loc.hasBearing()) loc.bearing.toDouble() else null,
                    "timestampMs" to loc.time,
                    "elapsedRealtimeNanos" to loc.elapsedRealtimeNanos,
                    "isMock" to loc.isFromMockProvider,
                    "provider" to (loc.provider ?: "fused"),
                )
                try {
                    sink?.success(payload)
                } catch (_: Exception) {
                    // Sink sudah ditutup bersamaan dgn callback terakhir — abaikan.
                }
            }

            override fun onLocationAvailability(availability: LocationAvailability) {
                // Bukan error fatal — cuma sinyal "belum ada fix saat ini"
                // (mis. baru masuk gedung). Biarkan Dart tetap menunggu
                // via existing acquire timeout, jangan matikan stream.
                if (!availability.isLocationAvailable) {
                    // no-op: engine Dart sudah punya deadline sendiri
                }
            }
        }
        callback = cb

        try {
            client.requestLocationUpdates(request, cb, Looper.getMainLooper())
        } catch (e: SecurityException) {
            events.error("PERMISSION_DENIED", "Izin lokasi belum granted", null)
        }
    }

    override fun onCancel(arguments: Any?) {
        val cb = callback ?: return
        client.removeLocationUpdates(cb)
        callback = null
        sink = null
    }

    // ── Method channel handler ──────────────────────────────────
    @SuppressLint("MissingPermission")
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getLastLocation" -> {
                try {
                    client.lastLocation
                        .addOnSuccessListener { loc ->
                            if (loc == null) {
                                result.success(null)
                            } else {
                                result.success(
                                    mapOf(
                                        "latitude" to loc.latitude,
                                        "longitude" to loc.longitude,
                                        "accuracy" to loc.accuracy.toDouble(),
                                        "timestampMs" to loc.time,
                                        "isMock" to loc.isFromMockProvider,
                                        "provider" to (loc.provider ?: "fused"),
                                    ),
                                )
                            }
                        }
                        .addOnFailureListener { result.success(null) }
                } catch (e: SecurityException) {
                    result.error("PERMISSION_DENIED", "Izin lokasi belum granted", null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
