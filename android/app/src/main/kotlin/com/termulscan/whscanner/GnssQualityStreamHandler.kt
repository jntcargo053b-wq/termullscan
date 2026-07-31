package com.termulscan.whscanner

// ============================================================
// GNSS QUALITY STREAM HANDLER
// ============================================================
// Membaca GnssStatus.Callback (API 24+, sesuai minSdk proyek ini)
// untuk mendapatkan info yang TIDAK bisa didapat dari FusedLocationProvider:
//   - jumlah satelit yang benar-benar dipakai dalam fix (usedInFix)
//   - rata-rata C/N0 (carrier-to-noise density, dB-Hz) dari satelit
//     yang dipakai — indikator kekuatan sinyal yang lebih jujur
//     daripada Position.accuracy semata (accuracy dari OS bisa optimis
//     walau geometri satelit/sinyal sebenarnya buruk, terutama saat
//     multipath di dalam gudang / dekat rak baja).
//
// Tidak perlu izin baru: registerGnssStatusCallback cukup dengan
// ACCESS_FINE_LOCATION yang sudah dideklarasikan di manifest.
//
// Tidak tersedia di iOS — kelas ini Android-only by design.
// ============================================================

import android.location.GnssStatus
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

class GnssQualityStreamHandler(
    private val locationManager: LocationManager,
) : EventChannel.StreamHandler {

    companion object {
        const val CHANNEL_NAME = "com.termulscan.whscanner/gnss_quality"

        // Ambang minimum C/N0 untuk dianggap "satelit sehat".
        // < 18 dB-Hz umumnya sangat lemah / hasil pantulan (multipath).
        private const val HEALTHY_CN0_THRESHOLD = 18.0f
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var callback: GnssStatus.Callback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        if (events == null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            // Di bawah API 24 tidak ada GnssStatus.Callback — kirim null
            // sekali lalu diam; sisi Dart akan menganggap GNSS quality
            // tidak tersedia dan fallback ke logika accuracy-only.
            events.success(null)
            return
        }

        val cb = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                var usedInFix = 0
                var totalCount = 0
                var cn0Sum = 0.0
                var cn0UsedCount = 0
                var healthyUsedCount = 0

                val n = status.satelliteCount
                for (i in 0 until n) {
                    totalCount++
                    val cn0 = status.getCn0DbHz(i)
                    if (status.usedInFix(i)) {
                        usedInFix++
                        cn0Sum += cn0
                        cn0UsedCount++
                        if (cn0 >= HEALTHY_CN0_THRESHOLD) healthyUsedCount++
                    }
                }

                val avgCn0 = if (cn0UsedCount > 0) cn0Sum / cn0UsedCount else 0.0

                val payload = mapOf(
                    "satellitesUsedInFix" to usedInFix,
                    "satellitesTotal" to totalCount,
                    "healthySatellitesUsed" to healthyUsedCount,
                    "avgCn0DbHz" to avgCn0,
                    "timestampMs" to System.currentTimeMillis(),
                )

                // GnssStatus.Callback dipanggil di thread yang didaftarkan;
                // pastikan events.success() dipanggil di main thread.
                mainHandler.post {
                    try {
                        events.success(payload)
                    } catch (_: Exception) {
                        // EventSink mungkin sudah ditutup (listener cancel
                        // bersamaan dengan callback terakhir) — abaikan.
                    }
                }
            }
        }
        callback = cb

        try {
            locationManager.registerGnssStatusCallback(cb, mainHandler)
        } catch (e: SecurityException) {
            // Izin lokasi belum granted saat listener didaftarkan — kirim
            // null, sisi Dart tetap jalan tanpa gating GNSS.
            events.success(null)
        }
    }

    override fun onCancel(arguments: Any?) {
        val cb = callback ?: return
        try {
            locationManager.unregisterGnssStatusCallback(cb)
        } catch (_: Exception) {
            // no-op
        }
        callback = null
    }
}
