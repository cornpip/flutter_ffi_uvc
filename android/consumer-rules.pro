# JNI_OnLoad looks these up with GetStaticMethodID, so nothing references
# them from Kotlin or Java and R8 would otherwise strip them.
-keepclassmembers class com.cornpip.flutter_ffi_uvc.FlutterFfiUvcPlugin {
    public static void onDeviceReleased(long, long);
    public static void onSessionDestroyed(long);
}
