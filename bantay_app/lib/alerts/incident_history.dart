class IncidentTimelineEvent {
  const IncidentTimelineEvent({
    required this.label,
    required this.at,
    this.detail,
  });

  final String label;
  final DateTime at;
  final String? detail;

  static IncidentTimelineEvent? parse(Object? raw) {
    if (raw is! Map) return null;
    final label = raw['label'];
    final atMs = raw['atEpochMs'];
    if (label is! String || atMs is! num) return null;
    final detail = raw['detail'];
    return IncidentTimelineEvent(
      label: label,
      at: DateTime.fromMillisecondsSinceEpoch(atMs.toInt()),
      detail: detail is String && detail.isNotEmpty ? detail : null,
    );
  }
}

class IncidentHistoryRecord {
  const IncidentHistoryRecord({
    required this.incidentId,
    required this.source,
    required this.stage,
    required this.timeline,
    this.occurredAt,
    this.peakG,
    this.beforeImpact,
    this.stillnessSeconds,
    this.contactName,
    this.number,
    this.smsText,
    this.error,
  });

  final String incidentId;
  final DateTime? occurredAt;
  final String source;
  final double? peakG;
  final String? beforeImpact;
  final int? stillnessSeconds;
  final String? contactName;
  final String? number;
  final String stage;
  final String? smsText;
  final String? error;
  final List<IncidentTimelineEvent> timeline;

  bool get isManual => source == 'manual_sos';
  bool get isCancelled => stage == 'canceled' || stage == 'cancelled';
  bool get isSent => stage == 'sent' || stage == 'delivered';

  static IncidentHistoryRecord? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['incidentId'];
    final source = raw['source'];
    final stage = raw['stage'];
    if (id is! String || id.isEmpty || source is! String || stage is! String) {
      return null;
    }

    DateTime? dateFrom(Object? value) => value is num
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : null;
    double? doubleFrom(Object? value) => value is num ? value.toDouble() : null;
    int? intFrom(Object? value) => value is num ? value.toInt() : null;
    String? stringFrom(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    final rawTimeline = raw['timeline'];

    return IncidentHistoryRecord(
      incidentId: id,
      occurredAt: dateFrom(raw['occurredAtEpochMs']),
      source: source,
      peakG: doubleFrom(raw['peakG']),
      beforeImpact: stringFrom(raw['beforeImpact']),
      stillnessSeconds: intFrom(raw['stillnessSeconds']),
      contactName: stringFrom(raw['contactName']),
      number: stringFrom(raw['number']),
      stage: stage,
      smsText: stringFrom(raw['smsText']),
      error: stringFrom(raw['error']),
      timeline: rawTimeline is List
          ? rawTimeline
                .map(IncidentTimelineEvent.parse)
                .whereType<IncidentTimelineEvent>()
                .toList()
          : const [],
    );
  }
}
