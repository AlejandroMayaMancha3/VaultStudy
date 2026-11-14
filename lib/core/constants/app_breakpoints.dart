/// Breakpoints and layout constants for VaultStudy adaptive UI.
abstract final class AppBreakpoints {
  /// Width threshold separating mobile (< 900px) and desktop (>= 900px) layouts.
  static const double desktop = 900.0;

  /// Fixed width for the left hierarchical tree sidebar on desktop.
  static const double desktopSidebarWidth = 260.0;

  /// Fixed height for the top command header on desktop.
  static const double desktopHeaderHeight = 56.0;

  /// Default subtle border radius range (6px to 12px) per user design spec.
  static const double radiusSm = 6.0;
  static const double radiusMd = 8.0;
  static const double radiusLg = 12.0;
}
