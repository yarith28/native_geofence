import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_geofence/src/generated/platform_bindings.g.dart';
import 'package:native_geofence_example/main.dart';

class FakeFlutterLocalNotificationsPlatform
    extends FlutterLocalNotificationsPlatform {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelPrefix = 'dev.flutter.pigeon.native_geofence.NativeGeofenceApi';

  void mockApiMethod(String method, List<Object?> Function(Object?) handler) {
    final channel = BasicMessageChannel<Object?>(
      '$channelPrefix.$method',
      NativeGeofenceApi.pigeonChannelCodec,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
      channel,
      (message) async => handler(message),
    );
  }

  setUpAll(() {
    // The platform interface starts uninitialized in widget-test isolates.
    // Install one explicit file-scoped implementation for every test here.
    FlutterLocalNotificationsPlatform.instance =
        FakeFlutterLocalNotificationsPlatform();
  });

  setUp(() {
    mockApiMethod('initialize', (_) => [null]);
    mockApiMethod('getGeofenceIds', (_) => [<String>[]]);
  });

  tearDown(() {
    for (final method in ['initialize', 'getGeofenceIds']) {
      final channel = BasicMessageChannel<Object?>(
        '$channelPrefix.$method',
        NativeGeofenceApi.pigeonChannelCodec,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(channel, null);
    }
  });

  testWidgets('renders the example app startup state',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Text && widget.data?.startsWith('Current state:') == true,
      ),
      findsOneWidget,
    );
  });
}
