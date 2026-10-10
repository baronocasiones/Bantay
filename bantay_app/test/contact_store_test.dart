import 'dart:io';

import 'package:bantay_app/alerts/contact_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'contact validates country code and persists without sample data',
    () async {
      final dir = await Directory.systemTemp.createTemp('bantay-contact');
      try {
        final store = ContactStore(directory: dir);
        expect(await store.load(), isNull);
        expect(EmergencyContact.validNumber('09123456789'), isFalse);
        expect(EmergencyContact.validNumber('+63 912 345 6789'), isTrue);
        const contact = EmergencyContact(
          name: 'Test Contact',
          number: '+63 912 345 6789',
          calibrated: true,
        );
        await store.save(contact);
        final restored = await store.load();
        expect(restored!.name, 'Test Contact');
        expect(restored.normalizedNumber, '+639123456789');
        expect(restored.calibrated, isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
