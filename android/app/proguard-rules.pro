# ============================================================
# Flutter ProGuard Rules
# ============================================================

# Ignore missing Play Core classes (deferred components / dynamic features)
-dontwarn com.google.android.play.core.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication

# Keep Play Core classes if present (optional)
-keep class com.google.android.play.core.** { *; }

# ============================================================
# Flutter Engine
# ============================================================
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Keep MainActivity
-keep class com.termulscan.whscanner.MainActivity { *; }

# ============================================================
# Model & Data Classes
# ============================================================
-keep class com.termulscan.whscanner.models.** { *; }
-keep class com.termulscan.whscanner.watermark.layouts.** { *; }

# ============================================================
# Native Methods
# ============================================================
-keepclasseswithmembernames class * {
    native <methods>;
}

# ============================================================
# Serialization
# ============================================================
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# ============================================================
# Plugins & Libraries
# ============================================================
-keep class com.google.gson.** { *; }
-keep class com.tekartik.sqflite.** { *; }
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class com.baseflow.permissionhandler.** { *; }
-keep class dev.fluttercommunity.plus.share.** { *; }
-keep class com.aboutyou.dart_packages.mobile_scanner.** { *; }
-keep class com.example.saver_gallery.** { *; }

# ============================================================
# App Package
# ============================================================
-keep class com.termulscan.whscanner.** { *; }

# ============================================================
# Enums
# ============================================================
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# ============================================================
# Ignore warnings (last resort)
# ============================================================
-ignorewarnings
