import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:math' as math;
import 'quiet_theme.dart';

/// Page 2's four 500 ms linear glow rotations; pause glyph stays upright.
class ConnectingControl extends StatefulWidget {
  const ConnectingControl({super.key});
  @override
  State<ConnectingControl> createState() => _ConnectingControlState();
}

class _ConnectingControlState extends State<ConnectingControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  PictureInfo? _glow, _glyph;
  @override
  void initState() {
    super.initState();
    _loadPictures();
  }
  Future<void> _loadPictures() async {
    final pictures = await Future.wait([
      vg.loadPicture(const SvgAssetLoader('assets/design/connecting_glow.svg'), null),
      vg.loadPicture(const SvgAssetLoader('assets/design/pause_glyph.svg'), null),
    ]);
    if (!mounted) {
      for (final picture in pictures) { picture.picture.dispose(); }
      return;
    }
    setState(() { _glow = pictures[0]; _glyph = pictures[1]; });
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _turn.stop();
    } else {
      _turn.repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    _glow?.picture.dispose();
    _glyph?.picture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ConnectingPainter(_turn, _glow, _glyph),
    child: const SizedBox.expand(),
  );
}

// Figma plus-darker: max(0, source + destination - 1).
// Invert both inputs, add, then invert the isolated result. Drawing both
// pictures on one canvas keeps the blend independent of Flutter's layers.
const _invert = ColorFilter.matrix([
  -1, 0, 0, 0, 255,
  0, -1, 0, 0, 255,
  0, 0, -1, 0, 255,
  0, 0, 0, 1, 0,
]);
class _ConnectingPainter extends CustomPainter {
  _ConnectingPainter(this.turn, this.glow, this.glyph) : super(repaint: turn);
  final Animation<double> turn;
  final PictureInfo? glow, glyph;
  void _picture(Canvas canvas, PictureInfo picture, Rect slot) {
    canvas.save();
    canvas.translate(slot.left, slot.top);
    canvas.scale(slot.width / picture.size.width, slot.height / picture.size.height);
    canvas.drawPicture(picture.picture);
    canvas.restore();
  }
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 56.356, size.height / 56.356);
    const bounds = Rect.fromLTWH(0, 0, 56.356, 56.356);
    canvas.clipPath(Path()..addOval(bounds));
    canvas.saveLayer(bounds, Paint()..colorFilter = _invert);
    canvas.saveLayer(bounds, Paint()..colorFilter = _invert);
    canvas.drawRect(bounds, Paint()..color = quietGreen);
    if (glow != null) {
      canvas.saveLayer(bounds.inflate(20), Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6));
      canvas.translate(28.178, 28.178);
      canvas.rotate(turn.value * 2 * math.pi);
      _picture(canvas, glow!, const Rect.fromLTWH(-43.8035, -43.8035, 87.607, 87.607));
      canvas.restore();
    }
    canvas.drawRect(bounds, Paint()..color = const Color(0x33299171));
    canvas.restore();
    if (glyph != null) {
      canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.plus..colorFilter = _invert);
      _picture(canvas, glyph!, const Rect.fromLTWH(18.386, 14.213, 19.584, 27.929));
      canvas.restore();
    }
    canvas.restore();
    canvas.restore();
  }
  @override
  bool shouldRepaint(_ConnectingPainter old) => old.glow != glow || old.glyph != glyph || old.turn != turn;
}

class LoadingMark extends StatefulWidget {
  const LoadingMark({super.key, this.onComplete});
  final VoidCallback? onComplete;
  @override
  State<LoadingMark> createState() => _LoadingMarkState();
}

class _LoadingMarkState extends State<LoadingMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  @override
  void initState() {
    super.initState();
    _animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onComplete?.call();
        });
      }
    });
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 1;
    } else {
      _animation.forward();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    builder: (context, _) {
      const frames = [
        'loading_dots',
        'loading_1',
        'loading_2',
        'loading_3',
        'loading',
      ];
      return quietAsset(
        frames[(_animation.value * 5).floor().clamp(0, 4)],
        220,
      );
    },
  );
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.text,
    this.error = false,
    this.child,
  });
  final String text;
  final bool error;
  final Widget? child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300),
    curve: Curves.easeOutCubic,
    builder: (context, value, _) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, (1 - value) * 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width.clamp(0, 520) * .8,
            ),
            margin: const EdgeInsets.only(bottom: 24, right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
            decoration: BoxDecoration(
              color: error ? quietRed : Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(22),
                topRight: Radius.circular(22),
                bottomRight: Radius.circular(22),
                bottomLeft: Radius.circular(3),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: quietText(
                    18,
                    color: error ? Colors.white : quietGreen,
                  ),
                ),
                if (child != null) child!,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class DividedProgress extends StatelessWidget {
  const DividedProgress({
    super.key,
    required this.divisions,
    required this.completed,
  });
  final int divisions, completed;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Прогресс поиска',
    value: '$completed/$divisions',
    child: SizedBox(
      height: 5,
      child: Row(
        children: [
          for (var i = 0; i < divisions; i++)
            Expanded(
              child: Container(
                margin: EdgeInsets.only(right: i == divisions - 1 ? 0 : 2),
                decoration: BoxDecoration(
                  color: i < completed ? Colors.white : quietNavy,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
