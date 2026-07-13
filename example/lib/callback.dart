import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:native_geofence/native_geofence.dart';
import 'package:native_geofence_example/notifications_repository.dart';

@pragma('vm:entry-point')
Future<void> geofenceTriggered(GeofenceCallbackParams params) async {
  debugPrint('geofenceTriggered params: $params');
  final SendPort? send =
      IsolateNameServer.lookupPortByName('native_geofence_send_port');
  final contexts = {
    for (final geofence in params.geofences)
      geofence.id: params.callbackContextsByGeofenceId[geofence.id],
  };
  send?.send(
    '${params.event.name} at ${params.eventAt} '
    '(delivery=${params.eventId}, contexts=$contexts)',
  );

  final notificationsRepository = NotificationsRepository();
  // Background callbacks run in their own isolate, so callback-safe plugin
  // dependencies must be initialized in that isolate before use.
  await notificationsRepository.init();

  final title =
      'Geofence ${capitalize(params.event.name)}: ${params.geofences.map((e) => e.id).join(', ')}';
  final message = 'Geofences:\n'
      '${params.geofences.map((e) => '• ID: ${e.id}, '
          'Radius=${e.radiusMeters.toStringAsFixed(0)}m, '
          'Context=${params.callbackContextsByGeofenceId[e.id]}, '
          'Triggers=${e.triggers.map((e) => e.name).join(',')}').join('\n')}\n'
      'Event: ${params.event.name}\n'
      'Event time: ${params.eventAt}\n'
      'Delivery ID: ${params.eventId}\n'
      'Location: ${params.location?.latitude.toStringAsFixed(5)}, '
      '${params.location?.longitude.toStringAsFixed(5)}';
  await notificationsRepository.showGeofenceTriggerNotification(title, message);
}

String capitalize(String text) {
  if (text.isEmpty) return text;
  return text[0].toUpperCase() + text.substring(1);
}
