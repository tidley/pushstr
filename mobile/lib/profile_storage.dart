String profileScopedKey(
  String? profileNsec,
  String legacyKey,
  String Function(String profileNsec) scopedKeyFor,
) {
  final secret = profileNsec?.trim() ?? '';
  if (secret.isEmpty) return legacyKey;
  return scopedKeyFor(secret);
}
