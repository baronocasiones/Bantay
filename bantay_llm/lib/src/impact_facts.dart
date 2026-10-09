enum AlertLanguage { english, tagalog }

enum BeforeImpact { walking, still, running, unknown }

enum AfterImpact { movedImmediately, noMovement }

/// Facts produced by Path 1. [occurredAt] must already be in local time.
class ImpactFacts {
  ImpactFacts({
    required this.occurredAt,
    required this.peakG,
    required this.beforeImpact,
    required this.afterImpact,
    required this.contactName,
    this.stillnessSeconds,
    this.latitude,
    this.longitude,
  }) {
    if (!peakG.isFinite || peakG < 0) {
      throw ArgumentError.value(peakG, 'peakG');
    }
    if (afterImpact == AfterImpact.noMovement &&
        (stillnessSeconds == null || stillnessSeconds! < 0)) {
      throw ArgumentError.value(stillnessSeconds, 'stillnessSeconds');
    }
    if ((latitude == null) != (longitude == null)) {
      throw ArgumentError('Latitude and longitude must both be set or absent.');
    }
    if (latitude != null &&
        (!latitude!.isFinite ||
            !longitude!.isFinite ||
            latitude! < -90 ||
            latitude! > 90 ||
            longitude! < -180 ||
            longitude! > 180)) {
      throw ArgumentError('Invalid coordinates.');
    }
    if (contactName.trim().isEmpty) {
      throw ArgumentError.value(contactName, 'contactName');
    }
  }

  final DateTime occurredAt;
  final double peakG;
  final BeforeImpact beforeImpact;
  final AfterImpact afterImpact;
  final int? stillnessSeconds;
  final double? latitude;
  final double? longitude;
  final String contactName;

  String get impactText => '${peakG.toStringAsFixed(1)}g';

  String get timeText {
    final hour = occurredAt.hour % 12 == 0 ? 12 : occurredAt.hour % 12;
    final minute = occurredAt.minute.toString().padLeft(2, '0');
    final period = occurredAt.hour < 12 ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  String? get coordinatesText => latitude == null
      ? null
      : '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}';
}
