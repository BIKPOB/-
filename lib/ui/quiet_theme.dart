import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const quietNavy = Color(0xFF010632);
const quietGreen = Color(0xFF299171);
const quietRed = Color(0xFFA7434F);
const quietGradient = LinearGradient(
  begin: Alignment.topRight,
  end: Alignment.bottomLeft,
  colors: [quietNavy, Color(0xFF068272)],
);
final quietTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  fontFamily: 'Bahnschrift',
  scaffoldBackgroundColor: quietNavy,
  colorScheme: ColorScheme.fromSeed(
    seedColor: quietGreen,
    brightness: Brightness.dark,
  ),
  textTheme: ThemeData.dark().textTheme
      .apply(fontFamily: 'Bahnschrift')
      .mapQuietFont(),
);

extension on TextTheme {
  TextTheme mapQuietFont() => copyWith(
    bodyMedium: bodyMedium?.copyWith(
      fontWeight: FontWeight.w300,
      fontVariations: const [FontVariation('wdth', 87.5)],
    ),
    bodyLarge: bodyLarge?.copyWith(
      fontWeight: FontWeight.w300,
      fontVariations: const [FontVariation('wdth', 87.5)],
    ),
  );
}

TextStyle quietText(
  double size, {
  Color color = Colors.white,
  bool bold = false,
}) => TextStyle(
  fontFamily: 'Bahnschrift',
  fontSize: size,
  color: color,
  height: 1.05,
  fontWeight: bold ? FontWeight.w700 : FontWeight.w300,
  fontVariations: [
    const FontVariation('wdth', 87.5),
    FontVariation('wght', bold ? 700 : 300),
  ],
);

Widget quietAsset(String name, double size) => SvgPicture.asset(
  'assets/design/$name.svg',
  width: size,
  height: size,
  fit: BoxFit.contain,
);

class QuietAction extends StatelessWidget {
  const QuietAction({
    super.key,
    required this.label,
    required this.child,
    this.onTap,
    this.color,
  });
  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final Color? color;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: label,
    child: Tooltip(
      message: label,
      child: Material(
        color: color ?? Colors.transparent,
        borderRadius: BorderRadius.circular(100),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedOpacity(
            opacity: onTap == null ? .45 : 1,
            duration: const Duration(milliseconds: 180),
            child: child,
          ),
        ),
      ),
    ),
  );
}
