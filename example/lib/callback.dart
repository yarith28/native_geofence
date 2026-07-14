import 'dart:isolate';
import 'dart:ui';

import 'package:native_geofence/native_geofence.dart';
import 'package:native_geofence_example/notifications_repository.dart';

@pragma('vm:entry-point')
Future<void> geofenceTriggered(GeofenceCallbackParams params) async {
  final SendPort? send =
      IsolateNameServer.lookupPortByName('native_geofence_send_port');
  final routedCount = params.geofences
      .where(
        (geofence) => params.callbackContextsByGeofenceId[geofence.id] == 1001,
      )
      .length;
  send?.send(
    '${params.event.name}: $routedCount routed geofence(s)',
  );

  final notificationsRepository = NotificationsRepository();
  // Background callbacks run in their own isolate, so callback-safe plugin
  // dependencies must be initialized in that isolate before use.
  await notificationsRepository.init();

  final title = 'Geofence ${capitalize(params.event.name)}';
  final message = 'Triggered geofences: ${params.geofences.length}\n'
      'Routed registrations: $routedCount\n'
      'Location metadata available: ${params.location != null}';
  await notificationsRepository.showGeofenceTriggerNotification(title, message);
}

String capitalize(String text) {
  if (text.isEmpty) return text;
  return text[0].toUpperCase() + text.substring(1);
}
