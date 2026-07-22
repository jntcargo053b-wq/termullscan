--- a/lib/watermark/layouts/minimal_layout.dart
+++ b/lib/watermark/layouts/minimal_layout.dart
@@ -31,7 +31,6 @@
   static const double _logoSpacing = 12.0;
   static const double _logoCardScale = 0.25;
   static const double _logoCardRadiusScale = 0.8;
-  static const double _iconSpace = 30.0;
 
   static const double _opacityOperator = 0.92;
   static const double _opacityTimestamp = 0.85;
@@ -265,15 +264,25 @@
           ? WatermarkTypography.lineHeight(valueFontSize)
           : metrics.lineHeight;
 
+      // ✅ FIX OVERLAP: dulu _iconSpace = 30.0 (fixed), sehingga saat user
+      // menaikkan pengaturan "Ukuran Font" (data.fontSize bisa sampai 48,
+      // dan baris barcode di-emphasize ×2.29 → glyph emoji bisa >100px),
+      // emoji ikon meluber keluar dari kotak 30px dan menimpa teks di
+      // sebelahnya (TextPainter tidak meng-clip glyph tunggal yang lebih
+      // lebar dari maxWidth). Sekarang lebar area ikon mengikuti ukuran
+      // font baris tersebut supaya ikon & teks tidak pernah bertabrakan,
+      // baik di font kecil maupun besar.
+      final iconSpace = valueFontSize * 1.3 + 4;
+
       final iconX = textAlign == TextAlign.left
           ? textStart
-          : textStart - _iconSpace;
+          : textStart - iconSpace;
       TextHelper.paintText(
         canvas: canvas,
         text: icon,
         x: iconX,
         y: textY,
-        maxWidth: _iconSpace,
+        maxWidth: iconSpace,
         color: color,
         fontSize: valueFontSize,
         fontWeight: FontWeight.normal,
@@ -283,14 +292,14 @@
       );
 
       final textX = textAlign == TextAlign.left
-          ? textStart + _iconSpace
-          : textStart - textContentWidth + _iconSpace;
+          ? textStart + iconSpace
+          : textStart - textContentWidth + iconSpace;
       TextHelper.paintText(
         canvas: canvas,
         text: text,
         x: textX,
         y: textY,
-        maxWidth: textContentWidth - _iconSpace,
+        maxWidth: textContentWidth - iconSpace,
         color: color,
         fontSize: valueFontSize,
         fontWeight: emphasize ? ui.FontWeight.w800 : ui.FontWeight.w500,
