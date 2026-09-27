import 'package:flutter/material.dart';
import 'package:once_power/config/theme/theme.dart';
import 'package:once_power/const/color.dart';
import 'package:once_power/const/num.dart';
import 'package:once_power/widget/base/tooltip.dart';

class EasyTooltip extends StatelessWidget {
  const EasyTooltip({
    super.key,
    this.tip,
    this.richMessage,
    this.textStyle,
    this.placement = TooltipDirection.right,
    this.waitDuration = const Duration(milliseconds: 800),
    required this.child,
  });

  final String? tip;
  final Widget? richMessage;
  final TextStyle? textStyle;
  final TooltipDirection placement;
  final Duration waitDuration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    return SmartTooltip(
      message: tip,
      textStyle:
          textStyle ??
          theme.textTheme.bodySmall?.copyWith(
            color: isDark ? AppColor.tooltipTextDark : AppColor.tooltipText,
          ),
      backgroundColor: isDark ? AppColor.tooltipDark : AppColor.tooltip,
      richMessage: richMessage,
      // decorationConfig: DecorationConfig(
      //   style: PaintingStyle.stroke,
      //   textColor: theme.textTheme.labelMedium?.color,
      //   backgroundColor: isDark ? AppColor.tooltipDark : AppColor.tooltip,
      // ),
      gap: AppNum.spaceSmall,
      placement: placement,
      waitDuration: waitDuration,
      contentPadding: .symmetric(horizontal: 8, vertical: 6),
      child: child,
    );
  }
}

TextSpan richTextTooltip(
  BuildContext context,
  String label,
  String desc, [
  bool isLast = false,
]) {
  desc = Characters(desc).join('\u{200B}');
  final theme = Theme.of(context);
  return TextSpan(
    text: '$label: ',
    style: TextStyle(
      fontSize: 13,
      color: theme.primaryColor.withValues(alpha: .8),
      fontFamily: defaultFont,
    ),
    children: [
      TextSpan(
        text: isLast ? desc : '$desc\n',
        style: TextStyle(
          fontSize: 13,
          color: theme.textTheme.labelMedium?.color,
          fontFamily: defaultFont,
        ),
      ),
    ],
  );
}
