import 'package:bantay_app/alerts/native_incident_gateway.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native snapshot keeps deadline, facts, manual flag, and exact text', () {
    final snapshot = NativeIncidentSnapshot.parse({
      'armed': true,
      'stage': 'counting',
      'incidentId': 'incident-1',
      'deadlineEpochMs': 1791600015000,
      'occurredAtEpochMs': 1791600000000,
      'peakG': 6.4,
      'beforeImpact': 'walking',
      'stillnessSeconds': 2,
      'manual': false,
      'text': 'BANTAY SOS: fixed alert',
      'number': '+630000000000',
    });
    expect(snapshot, isNotNull);
    expect(snapshot!.stage, NativeIncidentStage.counting);
    expect(snapshot.armed, isTrue);
    expect(snapshot.manual, isFalse);
    expect(snapshot.peakG, 6.4);
    expect(snapshot.text, 'BANTAY SOS: fixed alert');
    expect(
      snapshot.secondsLeft(DateTime.fromMillisecondsSinceEpoch(1791600005000)),
      10,
    );
  });

  test('malformed or unknown native stage does not present delivery', () {
    expect(NativeIncidentSnapshot.parse({'stage': 'surprise'}), isNull);
    final snapshot = NativeIncidentSnapshot.parse({
      'armed': true,
      'stage': 'unknown',
      'incidentId': 'incident-2',
      'manual': true,
    });
    expect(snapshot!.stage, NativeIncidentStage.unknown);
    expect(snapshot.manual, isTrue);
  });

  test('native gateway invokes cancel and send with same incident ID', () async {
    const channel = MethodChannel(nativeIncidentChannelName);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'armed': true,
            'stage': 'canceled',
            'incidentId': 'incident-1',
          };
        });
    final gateway = NativeIncidentGateway();
    await gateway.cancel('incident-1');
    await gateway.sendNow('incident-1');
    expect(calls.map((call) => call.method), [
      'cancelIncident',
      'sendHelpNow',
    ]);
    expect(calls.every((call) => call.arguments['incidentId'] == 'incident-1'),
        isTrue);
    gateway.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
