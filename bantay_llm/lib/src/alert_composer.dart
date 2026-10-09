import 'dart:async';

import 'impact_facts.dart';

abstract interface class AlertGenerator {
  Future<String> generate(String prompt);
  Future<void> stop();
}

class AlertResult {
  const AlertResult(this.text, {required this.llmUsed});

  final String text;
  final bool llmUsed;
}

/// Generates optional wording. The fixed alert remains available without AI.
class AlertComposer {
  const AlertComposer({
    AlertGenerator? generator,
    this.timeout = const Duration(seconds: 2),
    this.onCandidate,
  }) : _generator = generator;

  final AlertGenerator? _generator;
  final Duration timeout;

  /// Diagnostic observer. A candidate still needs to pass fact checks.
  final void Function(String text)? onCandidate;

  AlertResult fallback(ImpactFacts facts, AlertLanguage language) =>
      AlertResult(_fallback(facts, language), llmUsed: false);

  Future<AlertResult> compose(ImpactFacts facts, AlertLanguage language) async {
    final fallback = _fallback(facts, language);
    final generator = _generator;
    if (generator == null) return AlertResult(fallback, llmUsed: false);

    try {
      final output = await generator
          .generate(_prompt(facts, language))
          .timeout(
            timeout,
            onTimeout: () {
              unawaited(generator.stop().catchError((Object _) {}));
              return '';
            },
          );
      final candidate = output.trim();
      onCandidate?.call(candidate);
      if (_isGrounded(candidate, facts, language)) {
        return AlertResult(candidate, llmUsed: true);
      }
    } catch (_) {
      // Path 2 never prevents the fixed alert.
    }
    return AlertResult(fallback, llmUsed: false);
  }

  String _prompt(ImpactFacts facts, AlertLanguage language) {
    final requestedLanguage = language == AlertLanguage.tagalog
        ? 'Tagalog'
        : 'English';
    final uncertainEvent = language == AlertLanguage.tagalog
        ? 'Posibleng pagkahulog'
        : 'Possible fall';
    final motion = facts.afterImpact == AfterImpact.noMovement
        ? 'No movement for ${facts.stillnessSeconds} seconds'
        : 'Moved immediately';
    final before = facts.beforeImpact.name;
    final location = facts.coordinatesText ?? 'Location unavailable';
    final contact = facts.contactName.replaceAll(RegExp(r'[\r\n\t]'), ' ');
    return 'You write BANTAY safety alerts. Reply in $requestedLanguage with one '
        'calm, factual SMS under 40 words. Start with "BANTAY alert:". '
        'Use "$uncertainEvent", not a confirmed diagnosis. '
        'Include before-impact state, after-impact state, and location. '
        'Use only these facts. Keep numeric strings exactly as shown. '
        'Do not claim injury, consciousness, or safety. '
        'Do not add any new numbers.\n'
        'Impact: ${facts.impactText}\n'
        'Time: ${facts.timeText}\n'
        'Before impact: $before\n'
        'After impact: $motion\n'
        'Location: $location\n'
        'Contact: $contact\n'
        'MESSAGE:';
  }

  String _fallback(ImpactFacts facts, AlertLanguage language) {
    final location = facts.coordinatesText;
    if (language == AlertLanguage.tagalog) {
      final before = switch (facts.beforeImpact) {
        BeforeImpact.walking => 'Naglalakad',
        BeforeImpact.still => 'Nakatigil',
        BeforeImpact.running => 'Tumatakbo',
        BeforeImpact.unknown => 'Di tiyak ang galaw',
      };
      final after = facts.afterImpact == AfterImpact.noMovement
          ? 'walang galaw sa loob ng ${facts.stillnessSeconds} segundo'
          : 'gumalaw agad';
      return 'BANTAY alert: Posibleng pagkahulog noong ${facts.timeText}. '
          'Lakas ng tama: ${facts.impactText}. $before bago nito; $after. '
          'Lokasyon: ${location ?? 'hindi matukoy'}. Pakitingnan siya.';
    }

    final before = switch (facts.beforeImpact) {
      BeforeImpact.walking => 'walking',
      BeforeImpact.still => 'still',
      BeforeImpact.running => 'running',
      BeforeImpact.unknown => 'unknown movement',
    };
    final after = facts.afterImpact == AfterImpact.noMovement
        ? 'no movement for ${facts.stillnessSeconds} seconds'
        : 'moved immediately';
    return 'BANTAY alert: Possible fall at ${facts.timeText}. '
        '${facts.impactText} impact. Before: $before; after: $after. '
        'Location: ${location ?? 'Location unavailable'}. Please check on them.';
  }

  bool _isGrounded(String text, ImpactFacts facts, AlertLanguage language) {
    if (!text.startsWith('BANTAY alert:') ||
        text.isEmpty ||
        text.length > 320 ||
        text.contains(RegExp(r'[\r\n<>]')) ||
        text.split(RegExp(r'\s+')).length > 40 ||
        !text.contains(facts.impactText) ||
        !text.contains(facts.timeText)) {
      return false;
    }
    final coordinates = facts.coordinatesText;
    if (coordinates != null && !text.contains(coordinates)) return false;
    final lower = text.toLowerCase();
    if (coordinates == null &&
        !lower.contains('location unavailable') &&
        !lower.contains('hindi matukoy')) {
      return false;
    }
    if (facts.afterImpact == AfterImpact.noMovement &&
        (!text.contains('${facts.stillnessSeconds}') ||
            (!lower.contains('no movement') &&
                !lower.contains('walang galaw')))) {
      return false;
    }
    if (facts.afterImpact == AfterImpact.movedImmediately &&
        !lower.contains('moved immediately') &&
        !lower.contains('gumalaw agad')) {
      return false;
    }
    final beforeTerm = switch ((language, facts.beforeImpact)) {
      (AlertLanguage.english, BeforeImpact.walking) => 'walking',
      (AlertLanguage.english, BeforeImpact.still) => 'still',
      (AlertLanguage.english, BeforeImpact.running) => 'running',
      (AlertLanguage.english, BeforeImpact.unknown) => 'unknown',
      (AlertLanguage.tagalog, BeforeImpact.walking) => 'naglalakad',
      (AlertLanguage.tagalog, BeforeImpact.still) => 'nakatigil',
      (AlertLanguage.tagalog, BeforeImpact.running) => 'tumatakbo',
      (AlertLanguage.tagalog, BeforeImpact.unknown) => 'di tiyak',
    };
    if (!lower.contains(beforeTerm)) return false;
    final allowedNumbers = RegExp(r'\d+(?:\.\d+)?')
        .allMatches(
          [
            facts.impactText,
            facts.timeText,
            if (facts.afterImpact == AfterImpact.noMovement)
              '${facts.stillnessSeconds}',
            if (coordinates != null) coordinates,
          ].join(' '),
        )
        .map((match) => match.group(0))
        .toSet();
    for (final match in RegExp(r'\d+(?:\.\d+)?').allMatches(text)) {
      if (!allowedNumbers.contains(match.group(0))) return false;
    }
    if (language == AlertLanguage.english && !lower.contains('possible fall')) {
      return false;
    }
    if (language == AlertLanguage.tagalog &&
        !lower.contains('posibleng pagkahulog')) {
      return false;
    }
    if (lower.contains(
      RegExp(r'unconscious|injur|diagnos|died|dead|safe|confirmed fall'),
    )) {
      return false;
    }
    return true;
  }
}
