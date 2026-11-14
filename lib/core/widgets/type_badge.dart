import 'package:material_ui/material_ui.dart';
import '../../features/vault_tree/domain/vault_item.dart';
import '../constants/app_breakpoints.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// Compact monospace pill identifying item types (`PDF`, `LIBRO`, `NOTA`, `SRC`).
class TypeBadge extends StatelessWidget {
  const TypeBadge({
    super.key,
    required this.type,
    this.customLabel,
    this.inverted = false,
  });

  final VaultItemType type;
  final String? customLabel;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (type) {
      VaultItemType.pdf => (customLabel ?? 'PDF', AppColors.error),
      VaultItemType.book => (customLabel ?? 'LIBRO', AppColors.bookAmber),
      VaultItemType.note => (customLabel ?? 'NOTA', AppColors.secondary),
      VaultItemType.folder => (customLabel ?? 'DIR', AppColors.primary),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: inverted
            ? AppColors.surfaceLowest
            : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm - 2),
        border: Border.all(
          color: color.withValues(alpha: inverted ? 0.5 : 0.35),
          width: 0.8,
        ),
      ),
      child: Text(
        label,
        style: AppTypography.badgeMono.copyWith(color: color),
      ),
    );
  }
}
