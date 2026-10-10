import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class EmergencyContact {
  const EmergencyContact({
    required this.name,
    required this.number,
    this.calibrated = false,
  });
  final String name;
  final String number;
  final bool calibrated;
  static bool validName(String value) => value.trim().isNotEmpty;
  static bool validNumber(String value) =>
      RegExp(r'^\+[1-9]\d{7,14}$')
          .hasMatch(value.replaceAll(RegExp(r'[\s()-]'), ''));
  String get normalizedNumber => number.replaceAll(RegExp(r'[\s()-]'), '');
  Map<String, Object> toJson() => {
    'name': name.trim(),
    'number': normalizedNumber,
    'calibrated': calibrated,
  };
  static EmergencyContact? fromJson(Object? raw) {
    if (raw is! Map || raw['name'] is! String || raw['number'] is! String) {
      return null;
    }
    final name = raw['name'] as String;
    final number = raw['number'] as String;
    if (!validName(name) || !validNumber(number)) return null;
    return EmergencyContact(
      name: name,
      number: number,
      calibrated: raw['calibrated'] == true,
    );
  }
}

class ContactStore {
  ContactStore({this._directory});
  final Directory? _directory;
  Future<File> _file() async {
    final dir = _directory ?? await getApplicationDocumentsDirectory();
    return File('${dir.path}/bantay_contact.json');
  }

  Future<EmergencyContact?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      return EmergencyContact.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(EmergencyContact contact) async {
    if (!EmergencyContact.validName(contact.name) ||
        !EmergencyContact.validNumber(contact.number)) {
      throw ArgumentError('A name and international phone number are required');
    }
    final file = await _file();
    await file.writeAsString(jsonEncode(contact.toJson()), flush: true);
  }
}
