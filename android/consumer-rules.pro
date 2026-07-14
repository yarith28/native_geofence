# Manifest-configured processors are instantiated from their class name. Keep
# the implementation name, public no-argument constructor, and interface method
# available to NativeGeofenceBridge after application shrinking and obfuscation.
-keep class ** implements com.chunkytofustudios.native_geofence.bridge.NativeGeofenceEventProcessor {
    public <init>();
    public void processNativeGeofenceEvent(...);
}
