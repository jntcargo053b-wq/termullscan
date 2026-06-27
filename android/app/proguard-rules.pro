# Flutter specific
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Keep all classes from Flutter engine
-keep class com.termulscan.whscanner.MainActivity { *; }

# Keep model classes (ScanEntry, WatermarkData, etc.)
-keep class com.termulscan.whscanner.models.** { *; }

# Keep watermark layouts
-keep class com.termulscan.whscanner.watermark.layouts.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep serializable classes
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Keep all classes used by Gson (if any)
-keep class com.google.gson.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }

# For sqflite
-keep class com.tekartik.sqflite.** { *; }

# For image_picker
-keep class io.flutter.plugins.imagepicker.** { *; }

# For permission_handler
-keep class com.baseflow.permissionhandler.** { *; }

# For share_plus
-keep class dev.fluttercommunity.plus.share.** { *; }

# For mobile_scanner
-keep class com.aboutyou.dart_packages.mobile_scanner.** { *; }

# For saver_gallery
-keep class com.example.saver_gallery.** { *; }

# Keep all classes in app package
-keep class com.termulscan.whscanner.** { *; }

# Keep enums
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
