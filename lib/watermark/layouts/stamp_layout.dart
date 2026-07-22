--- a/lib/watermark/layouts/stamp_layout.dart
+++ b/lib/watermark/layouts/stamp_layout.dart
@@ -176,53 +176,100 @@
     );
 
     // ─── STAMP TEXT ────────────────────────────────────────────
-    final titleFontSize =
+    var titleFontSize =
         math.min(WatermarkTypography.title(data.fontSize), stampH * 0.32);
-    final captionFontSize =
+    var captionFontSize =
         math.min(WatermarkTypography.caption(data.fontSize), stampH * 0.18);
-    final titleLineH = WatermarkTypography.lineHeight(titleFontSize);
-    final captionLineH = WatermarkTypography.lineHeight(captionFontSize);
+    final stampTextMaxWidth = stampW - 24;
+    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(data.timestamp);
 
-    double textY = -stampH * 0.20;
+    // ✅ FIX OVERLAP: posisi baris di dalam lencana dulu memakai jarak
+    // "ajaib" (titleLineH*0.62, captionLineH*0.75) yang tidak selalu
+    // cukup menampung tinggi teks sebenarnya — pada kombinasi label +
+    // operator + tanggal (3 baris), baris tanggal bisa meluber keluar
+    // garis tepi lencana. Sekarang tinggi tiap baris DIUKUR langsung
+    // (TextHelper.measureText), lalu jika totalnya tidak muat di dalam
+    // tinggi lencana, seluruh font di dalam lencana diperkecil secara
+    // proporsional sampai benar-benar muat — dijamin tidak overlap.
+    const lineGapRatio = 0.18; // jarak antar baris, relatif thd font size
+    double measureTotalHeight() {
+      final gap = captionFontSize * lineGapRatio;
+      double h = TextHelper.measureText(
+        text: stampLabel,
+        maxWidth: stampTextMaxWidth,
+        fontSize: titleFontSize,
+        fontWeight: FontWeight.w900,
+        fontFamily: data.fontFamily,
+      ).height;
+      if (data.hasOperator) {
+        h += gap +
+            TextHelper.measureText(
+              text: data.operatorName.toUpperCase(),
+              maxWidth: stampTextMaxWidth,
+              fontSize: captionFontSize,
+              fontWeight: FontWeight.w600,
+              fontFamily: data.fontFamily,
+            ).height;
+      }
+      h += gap +
+          TextHelper.measureText(
+            text: dateStr,
+            maxWidth: stampTextMaxWidth,
+            fontSize: captionFontSize,
+            fontWeight: FontWeight.w600,
+            fontFamily: data.fontFamily,
+          ).height;
+      return h;
+    }
 
-    TextHelper.paintText(
+    final maxBlockHeight = stampH * 0.84; // sisakan margin atas/bawah ~8%
+    var totalHeight = measureTotalHeight();
+    if (totalHeight > maxBlockHeight && totalHeight > 0) {
+      final shrink = maxBlockHeight / totalHeight;
+      titleFontSize *= shrink;
+      captionFontSize *= shrink;
+      totalHeight = measureTotalHeight();
+    }
+
+    final gap = captionFontSize * lineGapRatio;
+    double textY = -totalHeight / 2;
+
+    final titleH = TextHelper.paintText(
       canvas: canvas,
       text: stampLabel,
       x: -stampW / 2 + 12,
       y: textY,
-      maxWidth: stampW - 24,
+      maxWidth: stampTextMaxWidth,
       color: stampColor,
       fontSize: titleFontSize,
       fontWeight: FontWeight.w900,
       textAlign: TextAlign.center,
       fontFamily: data.fontFamily,
     );
-
-    textY += titleLineH * 0.62;
+    textY += titleH + gap;
 
     if (data.hasOperator) {
-      TextHelper.paintText(
+      final opH = TextHelper.paintText(
         canvas: canvas,
         text: data.operatorName.toUpperCase(),
         x: -stampW / 2 + 12,
         y: textY,
-        maxWidth: stampW - 24,
+        maxWidth: stampTextMaxWidth,
         color: stampColor,
         fontSize: captionFontSize,
         fontWeight: FontWeight.w600,
         textAlign: TextAlign.center,
         fontFamily: data.fontFamily,
       );
-      textY += captionLineH * 0.75;
+      textY += opH + gap;
     }
 
-    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(data.timestamp);
     TextHelper.paintText(
       canvas: canvas,
       text: dateStr,
       x: -stampW / 2 + 12,
       y: textY,
-      maxWidth: stampW - 24,
+      maxWidth: stampTextMaxWidth,
       color: stampColor,
       fontSize: captionFontSize,
       fontWeight: FontWeight.w600,
