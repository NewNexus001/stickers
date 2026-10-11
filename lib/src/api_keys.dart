/// Google Fonts API key used by the font search page.
///
/// Provide it at build time so no secret is committed to the repository:
///
///     flutter build apk --release --dart-define=GOOGLE_FONTS_API_KEY=your_key
///
/// It defaults to an empty string so the project always compiles, even when
/// the key is not configured. Without a key the Google Fonts page will simply
/// report that it could not load the font list.
const String fontsKey = String.fromEnvironment(
  'GOOGLE_FONTS_API_KEY',
  defaultValue: '',
);
