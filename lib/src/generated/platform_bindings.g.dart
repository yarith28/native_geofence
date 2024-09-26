// Autogenerated from Pigeon (v22.4.0), do not edit directly.
// See also: https://pub.dev/packages/pigeon
// ignore_for_file: public_member_api_docs, non_constant_identifier_names, avoid_as, unused_import, unnecessary_parenthesis, prefer_null_aware_operators, omit_local_variable_types, unused_shown_name, unnecessary_import, no_leading_underscores_for_local_identifiers

import 'dart:async';
import 'dart:typed_data' show Float64List, Int32List, Int64List, Uint8List;

import 'package:flutter/foundation.dart' show ReadBuffer, WriteBuffer;
import 'package:flutter/services.dart';

PlatformException _createConnectionError(String channelName) {
  return PlatformException(
    code: 'channel-error',
    message: 'Unable to establish connection on channel: "$channelName".',
  );
}

List<Object?> wrapResponse({Object? result, PlatformException? error, bool empty = false}) {
  if (empty) {
    return <Object?>[];
  }
  if (error == null) {
    return <Object?>[result];
  }
  return <Object?>[error.code, error.message, error.details];
}

/// Geofencing events.
///
/// See the helpful illustration at:
/// https://developer.android.com/develop/sensors-and-location/location/geofencing
enum GeofenceEvent {
  enter,
  exit,
  /// Not supported on iOS.
  dwell,
}

/// Errors that can occur when interacting with the native geofence API.
enum NativeGeofenceErrorCode {
  unknown,
  pluginInternal,
  invalidArguments,
  channelError,
  missingLocationPermission,
  missingBackgroundLocationPermission,
  geofenceNotFound,
  callbackNotFound,
}

class LocationWire {
  LocationWire({
    required this.latitude,
    required this.longitude,
  });

  double latitude;

  double longitude;

  Object encode() {
    return <Object?>[
      latitude,
      longitude,
    ];
  }

  static LocationWire decode(Object result) {
    result as List<Object?>;
    return LocationWire(
      latitude: result[0]! as double,
      longitude: result[1]! as double,
    );
  }
}

class IosGeofenceSettingsWire {
  IosGeofenceSettingsWire({
    required this.initialTrigger,
  });

  bool initialTrigger;

  Object encode() {
    return <Object?>[
      initialTrigger,
    ];
  }

  static IosGeofenceSettingsWire decode(Object result) {
    result as List<Object?>;
    return IosGeofenceSettingsWire(
      initialTrigger: result[0]! as bool,
    );
  }
}

class AndroidGeofenceSettingsWire {
  AndroidGeofenceSettingsWire({
    required this.initialTriggers,
    this.expirationDurationMillis,
    required this.loiteringDelayMillis,
    this.notificationResponsivenessMillis,
  });

  List<GeofenceEvent> initialTriggers;

  int? expirationDurationMillis;

  int loiteringDelayMillis;

  int? notificationResponsivenessMillis;

  Object encode() {
    return <Object?>[
      initialTriggers,
      expirationDurationMillis,
      loiteringDelayMillis,
      notificationResponsivenessMillis,
    ];
  }

  static AndroidGeofenceSettingsWire decode(Object result) {
    result as List<Object?>;
    return AndroidGeofenceSettingsWire(
      initialTriggers: (result[0] as List<Object?>?)!.cast<GeofenceEvent>(),
      expirationDurationMillis: result[1] as int?,
      loiteringDelayMillis: result[2]! as int,
      notificationResponsivenessMillis: result[3] as int?,
    );
  }
}

class GeofenceWire {
  GeofenceWire({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    required this.iosSettings,
    required this.androidSettings,
    required this.callbackHandle,
  });

  String id;

  LocationWire location;

  double radiusMeters;

  List<GeofenceEvent> triggers;

  IosGeofenceSettingsWire iosSettings;

  AndroidGeofenceSettingsWire androidSettings;

  int callbackHandle;

  Object encode() {
    return <Object?>[
      id,
      location,
      radiusMeters,
      triggers,
      iosSettings,
      androidSettings,
      callbackHandle,
    ];
  }

  static GeofenceWire decode(Object result) {
    result as List<Object?>;
    return GeofenceWire(
      id: result[0]! as String,
      location: result[1]! as LocationWire,
      radiusMeters: result[2]! as double,
      triggers: (result[3] as List<Object?>?)!.cast<GeofenceEvent>(),
      iosSettings: result[4]! as IosGeofenceSettingsWire,
      androidSettings: result[5]! as AndroidGeofenceSettingsWire,
      callbackHandle: result[6]! as int,
    );
  }
}

class ActiveGeofenceWire {
  ActiveGeofenceWire({
    required this.id,
    required this.location,
    required this.radiusMeters,
    required this.triggers,
    this.androidSettings,
  });

  String id;

  LocationWire location;

  double radiusMeters;

  List<GeofenceEvent> triggers;

  AndroidGeofenceSettingsWire? androidSettings;

  Object encode() {
    return <Object?>[
      id,
      location,
      radiusMeters,
      triggers,
      androidSettings,
    ];
  }

  static ActiveGeofenceWire decode(Object result) {
    result as List<Object?>;
    return ActiveGeofenceWire(
      id: result[0]! as String,
      location: result[1]! as LocationWire,
      radiusMeters: result[2]! as double,
      triggers: (result[3] as List<Object?>?)!.cast<GeofenceEvent>(),
      androidSettings: result[4] as AndroidGeofenceSettingsWire?,
    );
  }
}

class GeofenceCallbackParams {
  GeofenceCallbackParams({
    required this.geofences,
    required this.event,
    this.location,
    required this.callbackHandle,
  });

  List<ActiveGeofenceWire> geofences;

  GeofenceEvent event;

  LocationWire? location;

  int callbackHandle;

  Object encode() {
    return <Object?>[
      geofences,
      event,
      location,
      callbackHandle,
    ];
  }

  static GeofenceCallbackParams decode(Object result) {
    result as List<Object?>;
    return GeofenceCallbackParams(
      geofences: (result[0] as List<Object?>?)!.cast<ActiveGeofenceWire>(),
      event: result[1]! as GeofenceEvent,
      location: result[2] as LocationWire?,
      callbackHandle: result[3]! as int,
    );
  }
}


class _PigeonCodec extends StandardMessageCodec {
  const _PigeonCodec();
  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is int) {
      buffer.putUint8(4);
      buffer.putInt64(value);
    }    else if (value is GeofenceEvent) {
      buffer.putUint8(129);
      writeValue(buffer, value.index);
    }    else if (value is NativeGeofenceErrorCode) {
      buffer.putUint8(130);
      writeValue(buffer, value.index);
    }    else if (value is LocationWire) {
      buffer.putUint8(131);
      writeValue(buffer, value.encode());
    }    else if (value is IosGeofenceSettingsWire) {
      buffer.putUint8(132);
      writeValue(buffer, value.encode());
    }    else if (value is AndroidGeofenceSettingsWire) {
      buffer.putUint8(133);
      writeValue(buffer, value.encode());
    }    else if (value is GeofenceWire) {
      buffer.putUint8(134);
      writeValue(buffer, value.encode());
    }    else if (value is ActiveGeofenceWire) {
      buffer.putUint8(135);
      writeValue(buffer, value.encode());
    }    else if (value is GeofenceCallbackParams) {
      buffer.putUint8(136);
      writeValue(buffer, value.encode());
    } else {
      super.writeValue(buffer, value);
    }
  }

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) {
    switch (type) {
      case 129: 
        final int? value = readValue(buffer) as int?;
        return value == null ? null : GeofenceEvent.values[value];
      case 130: 
        final int? value = readValue(buffer) as int?;
        return value == null ? null : NativeGeofenceErrorCode.values[value];
      case 131: 
        return LocationWire.decode(readValue(buffer)!);
      case 132: 
        return IosGeofenceSettingsWire.decode(readValue(buffer)!);
      case 133: 
        return AndroidGeofenceSettingsWire.decode(readValue(buffer)!);
      case 134: 
        return GeofenceWire.decode(readValue(buffer)!);
      case 135: 
        return ActiveGeofenceWire.decode(readValue(buffer)!);
      case 136: 
        return GeofenceCallbackParams.decode(readValue(buffer)!);
      default:
        return super.readValueOfType(type, buffer);
    }
  }
}

class NativeGeofenceApi {
  /// Constructor for [NativeGeofenceApi].  The [binaryMessenger] named argument is
  /// available for dependency injection.  If it is left null, the default
  /// BinaryMessenger will be used which routes to the host platform.
  NativeGeofenceApi({BinaryMessenger? binaryMessenger, String messageChannelSuffix = ''})
      : pigeonVar_binaryMessenger = binaryMessenger,
        pigeonVar_messageChannelSuffix = messageChannelSuffix.isNotEmpty ? '.$messageChannelSuffix' : '';
  final BinaryMessenger? pigeonVar_binaryMessenger;

  static const MessageCodec<Object?> pigeonChannelCodec = _PigeonCodec();

  final String pigeonVar_messageChannelSuffix;

  Future<void> initialize({required int callbackDispatcherHandle}) async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.initialize$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(<Object?>[callbackDispatcherHandle]) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> createGeofence({required GeofenceWire geofence}) async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.createGeofence$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(<Object?>[geofence]) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> reCreateAfterReboot() async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.reCreateAfterReboot$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(null) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<List<String>> getGeofenceIds() async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.getGeofenceIds$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(null) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else if (pigeonVar_replyList[0] == null) {
      throw PlatformException(
        code: 'null-error',
        message: 'Host platform returned null value for non-null return value.',
      );
    } else {
      return (pigeonVar_replyList[0] as List<Object?>?)!.cast<String>();
    }
  }

  Future<List<ActiveGeofenceWire>> getGeofences() async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.getGeofences$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(null) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else if (pigeonVar_replyList[0] == null) {
      throw PlatformException(
        code: 'null-error',
        message: 'Host platform returned null value for non-null return value.',
      );
    } else {
      return (pigeonVar_replyList[0] as List<Object?>?)!.cast<ActiveGeofenceWire>();
    }
  }

  Future<void> removeGeofenceById({required String id}) async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.removeGeofenceById$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(<Object?>[id]) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> removeAllGeofences() async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceApi.removeAllGeofences$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(null) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else {
      return;
    }
  }
}

class NativeGeofenceBackgroundApi {
  /// Constructor for [NativeGeofenceBackgroundApi].  The [binaryMessenger] named argument is
  /// available for dependency injection.  If it is left null, the default
  /// BinaryMessenger will be used which routes to the host platform.
  NativeGeofenceBackgroundApi({BinaryMessenger? binaryMessenger, String messageChannelSuffix = ''})
      : pigeonVar_binaryMessenger = binaryMessenger,
        pigeonVar_messageChannelSuffix = messageChannelSuffix.isNotEmpty ? '.$messageChannelSuffix' : '';
  final BinaryMessenger? pigeonVar_binaryMessenger;

  static const MessageCodec<Object?> pigeonChannelCodec = _PigeonCodec();

  final String pigeonVar_messageChannelSuffix;

  Future<void> triggerApiInitialized() async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceBackgroundApi.triggerApiInitialized$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(null) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> promoteToForeground() async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceBackgroundApi.promoteToForeground$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(null) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> demoteToBackground() async {
    final String pigeonVar_channelName = 'dev.flutter.pigeon.native_geofence.NativeGeofenceBackgroundApi.demoteToBackground$pigeonVar_messageChannelSuffix';
    final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
      pigeonVar_channelName,
      pigeonChannelCodec,
      binaryMessenger: pigeonVar_binaryMessenger,
    );
    final List<Object?>? pigeonVar_replyList =
        await pigeonVar_channel.send(null) as List<Object?>?;
    if (pigeonVar_replyList == null) {
      throw _createConnectionError(pigeonVar_channelName);
    } else if (pigeonVar_replyList.length > 1) {
      throw PlatformException(
        code: pigeonVar_replyList[0]! as String,
        message: pigeonVar_replyList[1] as String?,
        details: pigeonVar_replyList[2],
      );
    } else {
      return;
    }
  }
}

abstract class NativeGeofenceTriggerApi {
  static const MessageCodec<Object?> pigeonChannelCodec = _PigeonCodec();

  Future<void> geofenceTriggered(GeofenceCallbackParams params);

  static void setUp(NativeGeofenceTriggerApi? api, {BinaryMessenger? binaryMessenger, String messageChannelSuffix = '',}) {
    messageChannelSuffix = messageChannelSuffix.isNotEmpty ? '.$messageChannelSuffix' : '';
    {
      final BasicMessageChannel<Object?> pigeonVar_channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.native_geofence.NativeGeofenceTriggerApi.geofenceTriggered$messageChannelSuffix', pigeonChannelCodec,
          binaryMessenger: binaryMessenger);
      if (api == null) {
        pigeonVar_channel.setMessageHandler(null);
      } else {
        pigeonVar_channel.setMessageHandler((Object? message) async {
          assert(message != null,
          'Argument for dev.flutter.pigeon.native_geofence.NativeGeofenceTriggerApi.geofenceTriggered was null.');
          final List<Object?> args = (message as List<Object?>?)!;
          final GeofenceCallbackParams? arg_params = (args[0] as GeofenceCallbackParams?);
          assert(arg_params != null,
              'Argument for dev.flutter.pigeon.native_geofence.NativeGeofenceTriggerApi.geofenceTriggered was null, expected non-null GeofenceCallbackParams.');
          try {
            await api.geofenceTriggered(arg_params!);
            return wrapResponse(empty: true);
          } on PlatformException catch (e) {
            return wrapResponse(error: e);
          }          catch (e) {
            return wrapResponse(error: PlatformException(code: 'error', message: e.toString()));
          }
        });
      }
    }
  }
}
