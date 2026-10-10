import 'dart:async';

import 'package:flutter/services.dart';

const alertChannelName = 'ph.appbuilders.bantay_app/alerts';

enum SmsState { queued, sending, sent, delivered, failed, unknown }

SmsState? parseSmsState(Object? raw) {
  for (final value in SmsState.values) {
    if (raw == value.name) return value;
  }
  return null;
}

class SmsSubmission {
  const SmsSubmission(this.incidentId, this.state, {this.error});
  final String incidentId;
  final SmsState state;
  final String? error;
  static SmsSubmission? parse(Object? raw) {
    if (raw is! Map || raw['incidentId'] is! String) return null;
    final state = parseSmsState(raw['state']);
    if (state == null) return null;
    return SmsSubmission(
      raw['incidentId'] as String,
      state,
      error: raw['error'] as String?,
    );
  }
}

abstract interface class AlertGateway {
  Stream<SmsSubmission> get states;
  Future<bool> smsPermissionStatus();
  Future<bool> requestSmsPermission();
  Future<SmsSubmission> send({
    required String incidentId,
    required String number,
    required String body,
  });
  Future<List<SmsSubmission>> outboxSnapshot();
  void dispose();
}

class NativeAlertGateway implements AlertGateway {
  NativeAlertGateway() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'smsState') return;
      final event = SmsSubmission.parse(call.arguments);
      if (event != null) _states.add(event);
    });
  }
  final MethodChannel _channel = const MethodChannel(alertChannelName);
  final StreamController<SmsSubmission> _states =
      StreamController<SmsSubmission>.broadcast();
  @override
  Stream<SmsSubmission> get states => _states.stream;
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
    _states.close();
  }
}
