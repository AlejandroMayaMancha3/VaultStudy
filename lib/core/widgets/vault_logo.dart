import 'package:material_ui/material_ui.dart';
import '../constants/app_breakpoints.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// Unified VaultStudy brand mark: safe/vault vector icon + "VAULTSTUDY" wordmark.
class VaultLogo extends StatelessWidget {
  const VaultLogo({
    super.key,
    this.compact = false,
    this.uppercaseWordmark = true,
  });

  final bool compact;
  final bool uppercaseWordmark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: AppColors.primaryContainer.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.35),
            ),
          ),
          child: const Center(
            child: CustomPaint(
              size: Size(20, 20),
              painter: _VaultSafeIconPainter(color: AppColors.primary),
            ),
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 10),
          RichText(
            text: TextSpan(
              style: AppTypography.headlineSm.copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
              children: [
                TextSpan(
                  text: uppercaseWordmark ? 'VAULT' : 'Vault',
                  style: const TextStyle(color: AppColors.onSurface),
                ),
                TextSpan(
                  text: uppercaseWordmark ? 'STUDY' : 'Study',
                  style: const TextStyle(color: AppColors.primary),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _VaultSafeIconPainter extends CustomPainter {
  const _VaultSafeIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9 * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Outer vault door rect (3, 3, 18, 18, rx=2)
    final doorRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(3 * sx, 3 * sy, 18 * sx, 18 * sy),
      Radius.circular(2.5 * sx),
    );
    canvas.drawRRect(doorRect, stroke);

    // Dial center circle (12, 12, r=2.2)
    canvas.drawCircle(Offset(12 * sx, 12 * sy), 2.3 * sx, stroke);

    // Dial handle line (13.6, 13.6 -> 16.5, 16.5)
    canvas.drawLine(
      Offset(13.6 * sx, 13.6 * sy),
      Offset(16.6 * sx, 16.6 * sy),
      stroke,
    );

    // Top-left and top-right bolt dots
    canvas.drawCircle(Offset(7.5 * sx, 7.5 * sy), 1.0 * sx, fill);
    canvas.drawCircle(Offset(16.5 * sx, 7.5 * sy), 1.0 * sx, fill);
  }

  @override
  bool shouldRepaint(covariant _VaultSafeIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
