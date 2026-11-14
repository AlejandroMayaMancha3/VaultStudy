import 'package:material_ui/material_ui.dart';
import '../constants/app_breakpoints.dart';
import 'app_colors.dart';
import 'app_typography.dart';

/// Application-wide Material 3 dark theme configured for VaultStudy.
abstract final class AppTheme {
  static ThemeData get dark {
    const colorScheme = ColorScheme.dark(
      surface: AppColors.surface,
      onSurface: AppColors.onSurface,
      surfaceContainerLowest: AppColors.surfaceLowest,
      surfaceContainerLow: AppColors.surfaceLow,
      surfaceContainer: AppColors.surfaceContainer,
      surfaceContainerHigh: AppColors.surfaceHigh,
      surfaceContainerHighest: AppColors.surfaceHighest,
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      primaryContainer: AppColors.primaryContainer,
      onPrimaryContainer: AppColors.onPrimaryContainer,
      secondary: AppColors.secondary,
      onSecondary: AppColors.onSecondary,
      secondaryContainer: AppColors.secondaryContainer,
      tertiary: AppColors.tertiary,
      error: AppColors.error,
      onError: AppColors.onError,
      errorContainer: AppColors.errorContainer,
      outline: AppColors.outline,
      outlineVariant: AppColors.outlineVariant,
      onSurfaceVariant: AppColors.onSurfaceVariant,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.surface,
      fontFamily: AppTypography.fontBody,
      dividerColor: AppColors.outlineVariant.withValues(alpha: 0.6),
      textTheme: const TextTheme(
        headlineLarge: AppTypography.headlineLg,
        headlineMedium: AppTypography.headlineMd,
        headlineSmall: AppTypography.headlineSm,
        titleLarge: AppTypography.headlineMd,
        titleMedium: AppTypography.headlineSm,
        bodyLarge: AppTypography.bodyLg,
        bodyMedium: AppTypography.bodyMd,
        bodySmall: AppTypography.bodySm,
        labelLarge: AppTypography.labelMono,
        labelMedium: AppTypography.labelMono,
        labelSmall: AppTypography.badgeMono,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surfaceContainer,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          side: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surfaceLow,
        elevation: 16,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusLg),
          side: const BorderSide(color: AppColors.outlineVariant),
        ),
        titleTextStyle: AppTypography.headlineSm,
        contentTextStyle: AppTypography.bodyMd,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceLowest,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        hintStyle: AppTypography.bodyMd.copyWith(color: AppColors.outline),
        labelStyle: AppTypography.monoSm.copyWith(color: AppColors.outline),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          borderSide: const BorderSide(color: AppColors.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          borderSide: const BorderSide(color: AppColors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          borderSide: const BorderSide(color: AppColors.secondary, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryContainer,
          foregroundColor: AppColors.surfaceLowest,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: AppTypography.labelMono.copyWith(
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.onSurface,
          side: const BorderSide(color: AppColors.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          textStyle: AppTypography.labelMono,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.secondary,
          textStyle: AppTypography.labelMono,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.surfaceHigh,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          side: const BorderSide(color: AppColors.outlineVariant),
        ),
        textStyle: AppTypography.bodySm.copyWith(color: AppColors.onSurface),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceHighest,
        contentTextStyle: AppTypography.monoSm.copyWith(
          color: AppColors.onSurface,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          side: const BorderSide(color: AppColors.outlineVariant),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          AppColors.outlineVariant.withValues(alpha: 0.8),
        ),
        radius: const Radius.circular(4),
        thickness: const WidgetStatePropertyAll(6),
      ),
    );
  }
}
