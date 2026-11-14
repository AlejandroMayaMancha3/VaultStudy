/// Public client configuration for VaultStudy's Supabase backend.
/// Can be overridden at build time via `--dart-define` or `--dart-define-from-file=.env`.
/// Access is strictly isolated per authenticated user via Postgres & Storage RLS.
class SupabaseConfig {
  SupabaseConfig._();

  static const String projectUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://evdoxxyyoifmdfyvatfi.supabase.co',
  );
  static const String publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_Axy23Njb8BCJCQDZNlKVFw_b7MlmGRk',
  );
  static const String storageBucket = String.fromEnvironment(
    'SUPABASE_STORAGE_BUCKET',
    defaultValue: 'vault-files',
  );
}
