import 'dart:async';

import 'package:bantay_app/alerts/alert_gateway.dart';
import 'package:flutter/services.dart';

const nativeIncidentChannelName = 'ph.appbuilders.bantay_app/alerts';

enum NativeIncidentStage {
  idle,
  counting,
  canceled,
  sending,
  queued,
  sent,
  delivered,
  failed,
  unknown,
}

class NativeIncidentSnapshot {
  const NativeIncidentSnapshot({
    required this.armed,
    required this.stage,
    this.incidentId,
    this.deadline,
    this.occurredAt,
    this.peakG,
    this.beforeImpact,
    this.stillnessSeconds,
    this.manual = false,
    this.text,
    this.number,
    this.error,
  });

  final bool armed;
  final NativeIncidentStage stage;
  final String? incidentId;
  final DateTime? deadline;
  final DateTime? occurredAt;
  final double? peakG;
  final String? beforeImpact;
  final int? stillnessSeconds;
  final bool manual;
  final String? text;
  final String? number;
  final String? error;

  bool get counting => stage == NativeIncidentStage.counting;

  int secondsLeft(DateTime now) {
    final deadline = this.deadline;
    if (deadline == null || !counting) return 0;
    final remaining = deadline.difference(now).inMilliseconds;
    if (remaining <= 0) return 0;
    return (remaining / 1000).ceil();
  }

  static NativeIncidentSnapshot? parse(Object? raw) {
    if (raw is! Map) return null;
    final stageRaw = raw['stage'];
    NativeIncidentStage? stage;
    for (final value in NativeIncidentStage.values) {
      if (stageRaw == value.name) {
        stage = value;
        break;
      }
    }
    if (stage == null) return null;
    final deadlineMs = raw['deadlineEpochMs'];
    final occurredMs = raw['occurredAtEpochMs'];
    final peakG = raw['peakG'];
    final stillnessSeconds = raw['stillnessSeconds'];
    return NativeIncidentSnapshot(
      armed: raw['armed'] == true,
      stage: stage,
      incidentId: raw['incidentId'] as String?,
      deadline: deadlineMs is num
          ? DateTime.fromMillisecondsSinceEpoch(deadlineMs.toInt())
          : null,
      occurredAt: occurredMs is num
          ? DateTime.fromMillisecondsSinceEpoch(occurredMs.toInt())
          : null,
      peakG: peakG is num ? peakG.toDouble() : null,
      beforeImpact: raw['beforeImpact'] as String?,
      stillnessSeconds:
          stillnessSeconds is num ? stillnessSeconds.toInt() : null,
      manual: raw['manual'] == true,
      text: raw['text'] as String?,
      number: raw['number'] as String?,
      error: raw['error'] as String?,
    );
  }
}

class DetectorDiagnostics {
  const DetectorDiagnostics({
    this.lastPeakG,
    this.impactThresholdCrossed = false,
    this.rotationDegrees,
    this.stillnessMs,
    this.rejectReason,
  });
  final double? lastPeakG;
  final bool impactThresholdCrossed;
  final double? rotationDegrees;
  final int? stillnessMs;
  final String? rejectReason;

  static DetectorDiagnostics? parse(Object? raw) {
    if (raw is! Map) return null;
    final peak = raw['lastPeakG'];
    final rotation = raw['rotationDegrees'];
    final stillness = raw['stillnessMs'];
    return DetectorDiagnostics(
      lastPeakG: peak is num ? peak.toDouble() : null,
      impactThresholdCrossed: raw['impactThresholdCrossed'] == true,
      rotationDegrees: rotation is num ? rotation.toDouble() : null,
      stillnessMs: stillness is num ? stillness.toInt() : null,
      rejectReason: raw['rejectReason'] as String?,
    );
  }
}

/// One handler owns every native alert event; a second handler on this
/// MethodChannel would silently replace the first.
class NativeIncidentGateway implements AlertGateway {
  NativeIncidentGateway() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'incidentState':
          final snapshot = NativeIncidentSnapshot.parse(call.arguments);
          if (snapshot != null) _incidents.add(snapshot);
        case 'detectorDiagnostics':
          final diagnostics = DetectorDiagnostics.parse(call.arguments);
          if (diagnostics != null) _diagnostics.add(diagnostics);
        case 'smsState':
          final state = SmsSubmission.parse(call.arguments);
          if (state != null) _smsStates.add(state);
      }
    });
  }

  final MethodChannel _channel = const MethodChannel(nativeIncidentChannelName);
  final StreamController<NativeIncidentSnapshot> _incidents =
      StreamController<NativeIncidentSnapshot>.broadcast();
  final StreamController<DetectorDiagnostics> _diagnostics =
      StreamController<DetectorDiagnostics>.broadcast();
  final StreamController<SmsSubmission> _smsStates =
      StreamController<SmsSubmission>.broadcast();

  Stream<NativeIncidentSnapshot> get incidents => _incidents.stream;
  Stream<DetectorDiagnostics> get diagnostics => _diagnostics.stream;
  @override
  Stream<SmsSubmission> get states => _smsStates.stream;

  Future<NativeIncidentSnapshot?> arm({
    required String contactName,
    required String number,
  }) async => NativeIncidentSnapshot.parse(
    await _channel.invokeMethod<Object?>('armGuardian', {
      'contactName': contactName,
      'number': number,
    }),
  );

  Future<NativeIncidentSnapshot?> snapshot() async =>
      NativeIncidentSnapshot.parse(
        await _channel.invokeMethod<Object?>('incidentSnapshot'),
      );

  Future<DetectorDiagnostics?> detectorSnapshot() async =>
      DetectorDiagnostics.parse(
        await _channel.invokeMethod<Object?>('detectorDiagnostics'),
      );

  Future<NativeIncidentSnapshot?> startManualSos() async =>
      NativeIncidentSnapshot.parse(
        await _channel.invokeMethod<Object?>('startManualSos'),
      );

  Future<NativeIncidentSnapshot?> cancel(String incidentId) async =>
      NativeIncidentSnapshot.parse(
        await _channel.invokeMethod<Object?>('cancelIncident', {
          'incidentId': incidentId,
        }),
      );

  Future<NativeIncidentSnapshot?> sendNow(String incidentId) async =>
      NativeIncidentSnapshot.parse(
        await _channel.invokeMethod<Object?>('sendHelpNow', {
          'incidentId': incidentId,
        }),
      );

  Future<bool> setIncidentText(String incidentId, String text) async =>
      await _channel.invokeMethod<bool>('setIncidentText', {
        'incidentId': incidentId,
        'text': text,
      }) ??
      false;

  @override
  Future<bool> smsPermissionStatus() async =>
      await _channel.invokeMethod<bool>('smsPermissionStatus') ?? false;

  @override
  Future<bool> requestSmsPermission() async =>
      await _channel.invokeMethod<bool>('requestSmsPermission') ?? false;

  @override
  Future<SmsSubmission> send({
    required String incidentId,
    required String number,
    required String body,
  }) async {
    final raw = await _channel.invokeMethod<Object?>('sendSms', {
      'incidentId': incidentId,
      'number': number,
      'text': body,
    });
    return SmsSubmission.parse(raw) ??
        SmsSubmission(
          incidentId,
          SmsState.failed,
          error: 'Invalid native SMS response',
        );
  }

  @override
  Future<List<SmsSubmission>> outboxSnapshot() async {
    final raw = await _channel.invokeMethod<Object?>('outboxSnapshot');
    return (raw is List ? raw : const [])
        .map(SmsSubmission.parse)
        .whereType<SmsSubmission>()
        .toList();
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _incidents.close();
    _diagnostics.close();
    _smsStates.close();
  }
}
