import 'package:flutter_test/flutter_test.dart';
import 'package:pushstr/profile_storage.dart';

void main() {
  group('profileScopedKey', () {
    test('uses legacy key when no profile secret exists', () {
      final key = profileScopedKey(
        null,
        'messages',
        (secret) => 'messages_$secret',
      );

      expect(key, 'messages');
    });

    test('uses legacy key when profile secret is empty', () {
      final key = profileScopedKey(
        '   ',
        'contacts',
        (secret) => 'contacts_$secret',
      );

      expect(key, 'contacts');
    });

    test('uses scoped key when profile secret exists', () {
      final key = profileScopedKey(
        'nsec1abc123',
        'pending_dms',
        (secret) => 'pending_dms_$secret',
      );

      expect(key, 'pending_dms_nsec1abc123');
    });
  });
}
