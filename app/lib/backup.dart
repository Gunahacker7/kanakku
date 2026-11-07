/// Backup / restore (v1.0). A backup is ONE JSON document holding
/// every on-device store, shared through the normal FileProvider
/// share sheet:
///
///     {
///       "app": "kanakku",
///       "formatVersion": 1,
///       "createdAt": 1234567890,
///       "stores": { "manual": "...", "removed": "..." },
///       "settings": { }        // same document as settings_store
///     }
///
/// v1.0.4 (audit F5) adds an OPTIONAL encrypted form — the plain
/// document above is passphrase-encrypted natively (PBKDF2 +
/// AES-GCM) and wrapped in an envelope:
///
///     {
///       "app": "kanakku",
///       "formatVersion": 2,
///       "enc": true,
///       "createdAt": 1234567890,
///       "data": "<base64 salt|iv|ciphertext>"
///     }
///
/// The PIN is NEVER included in either form: the salted hash lives
/// in its own native store and is not readable through the store
/// channel. Store values ride as their original JSON strings so a
/// restore writes them back byte-for-byte.
library;

import 'dart:convert';

const backupFormatVersion = 1;

/// Envelope version for passphrase-encrypted backups (v1.0.4).
const backupEncryptedFormatVersion = 2;

/// Store keys that make up a full backup. v1.1 (spec §6.2) adds
/// 'recurring' — inside the SAME envelope versions (the key is
/// additive; v1.0.4 ignores it on restore, and a v1.0.4 backup
/// without the key restores as "leave the recurring store
/// untouched"). Alert state is NEVER backed up (spec §2.3).
const backupStoreKeys = <String>[
  'manual',
  'removed',
  'splits',
  'budgets',
  'statement',
  'categories',
  'recurring',
];

Map<String, dynamic> buildBackup({
  required Map<String, String> stores,
  required Map<String, dynamic> settings,
  required DateTime createdAt,
}) => {
  'app': 'kanakku',
  'formatVersion': backupFormatVersion,
  'createdAt': createdAt.millisecondsSinceEpoch,
  'stores': {for (final k in backupStoreKeys) k: stores[k] ?? ''},
  'settings': settings,
};

String encodeBackup(Map<String, dynamic> backup) =>
    const JsonEncoder.withIndent('  ').convert(backup);

/// Wraps a natively-encrypted backup blob (Base64 of
/// salt|iv|ciphertext from BackupCrypto) in its JSON envelope.
Map<String, dynamic> buildEncryptedBackup({
  required String data,
  required DateTime createdAt,
}) => {
  'app': 'kanakku',
  'formatVersion': backupEncryptedFormatVersion,
  'enc': true,
  'createdAt': createdAt.millisecondsSinceEpoch,
  'data': data,
};

/// Validates a backup document. On success returns the store writes
/// plus the settings document (plain backups), or — for an encrypted
/// envelope — [encryptedBlob] set and empty stores: the caller must
/// decrypt the blob with the user's passphrase and run [parseBackup]
/// again on the plaintext before writing anything. Returns null
/// when the file is not a Kanakku backup of a supported version.
({
  Map<String, String> stores,
  Map<String, dynamic>? settings,
  String? encryptedBlob,
})?
parseBackup(String text) {
  try {
    final map = jsonDecode(text);
    if (map is! Map) return null;
    final m = Map<String, dynamic>.from(map);
    if (m['app'] != 'kanakku') return null;
    final version = (m['formatVersion'] as num?)?.toInt();
    if (version == backupEncryptedFormatVersion) {
      if (m['enc'] != true) return null;
      final data = m['data'];
      if (data is! String || data.isEmpty) return null;
      return (stores: <String, String>{}, settings: null, encryptedBlob: data);
    }
    if (version != backupFormatVersion) {
      return null;
    }
    final rawStores = m['stores'];
    if (rawStores is! Map) return null;
    final stores = <String, String>{};
    for (final k in backupStoreKeys) {
      final v = rawStores[k];
      if (v == null) continue;
      if (v is! String) return null;
      // Each payload must itself be valid JSON (a list or a map).
      final parsed = jsonDecode(v.isEmpty ? 'null' : v);
      if (parsed != null && parsed is! List && parsed is! Map) return null;
      stores[k] = v;
    }
    if (stores.isEmpty) return null;
    Map<String, dynamic>? settings;
    final rawSettings = m['settings'];
    if (rawSettings is Map) {
      settings = Map<String, dynamic>.from(rawSettings);
    }
    return (stores: stores, settings: settings, encryptedBlob: null);
  } catch (_) {
    return null;
  }
}
