import 'package:material_ui/material_ui.dart';

/// Color tokens derived from the VaultStudy Research Terminal design system.
abstract final class AppColors {
  // Surfaces
  static const Color surfaceLowest = Color(0xFF0A0E14);
  static const Color surface = Color(0xFF101419);
  static const Color surfaceLow = Color(0xFF181C21);
  static const Color surfaceContainer = Color(0xFF1C2025);
  static const Color surfaceHigh = Color(0xFF262A30);
  static const Color surfaceHighest = Color(0xFF31353B);
  static const Color surfaceBright = Color(0xFF36393F);

  // Brand & Accents
  static const Color primary = Color(0xFF4EDEA3);
  static const Color primaryContainer = Color(0xFF10B981);
  static const Color primaryFixed = Color(0xFF6FFBBE);
  static const Color onPrimary = Color(0xFF003824);
  static const Color onPrimaryContainer = Color(0xFF00422B);

  static const Color secondary = Color(0xFF7BD0FF);
  static const Color secondaryContainer = Color(0xFF00A6E0);
  static const Color onSecondary = Color(0xFF00354A);

  static const Color tertiary = Color(0xFFC0C1FF);
  static const Color tertiaryContainer = Color(0xFF9699FF);

  static const Color error = Color(0xFFFFB4AB);
  static const Color errorContainer = Color(0xFF93000A);
  static const Color onError = Color(0xFF690005);

  /// Distinct amber accent for textbook PDFs (`LIBRO` badge).
  static const Color bookAmber = Color(0xFFF59E0B);

  // Text & Outlines
  static const Color onSurface = Color(0xFFE0E2EA);
  static const Color onSurfaceVariant = Color(0xFFBBCABF);
  static const Color outline = Color(0xFF86948A);
  static const Color outlineVariant = Color(0xFF3C4A42);
}
