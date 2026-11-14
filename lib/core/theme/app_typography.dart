import 'package:material_ui/material_ui.dart';
import 'app_colors.dart';

/// Typography scale combining:
/// - Space Grotesk for headlines
/// - Inter for long-form reading & notes
/// - JetBrains Mono exclusively for code, paths, badges, and shortcuts
abstract final class AppTypography {
  static const String fontHeadline = 'SpaceGrotesk';
  static const String fontBody = 'Inter';
  static const String fontMono = 'JetBrainsMono';

  static const TextStyle headlineLg = TextStyle(
    fontFamily: fontHeadline,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.25,
    letterSpacing: -0.4,
    color: AppColors.onSurface,
  );

  static const TextStyle headlineMd = TextStyle(
    fontFamily: fontHeadline,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: -0.25,
    color: AppColors.onSurface,
  );

  static const TextStyle headlineSm = TextStyle(
    fontFamily: fontHeadline,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.35,
    letterSpacing: -0.1,
    color: AppColors.onSurface,
  );

  static const TextStyle bodyLg = TextStyle(
    fontFamily: fontBody,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.65,
    color: AppColors.onSurface,
  );

  static const TextStyle bodyMd = TextStyle(
    fontFamily: fontBody,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.55,
    color: AppColors.onSurface,
  );

  static const TextStyle bodySm = TextStyle(
    fontFamily: fontBody,
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
    height: 1.45,
    color: AppColors.onSurfaceVariant,
  );

  static const TextStyle monoMd = TextStyle(
    fontFamily: fontMono,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.onSurface,
  );

  static const TextStyle monoSm = TextStyle(
    fontFamily: fontMono,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    height: 1.35,
    color: AppColors.onSurfaceVariant,
  );

  static const TextStyle labelMono = TextStyle(
    fontFamily: fontMono,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: 0.7,
    color: AppColors.onSurfaceVariant,
  );

  static const TextStyle badgeMono = TextStyle(
    fontFamily: fontMono,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    height: 1.1,
    letterSpacing: 0.5,
  );
}
