import 'package:flutter/material.dart';
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipOval(
    child: Stack(
      alignment: Alignment.center,
      children: [
        RotationTransition(
          turns: _turn,
          child: OverflowBox(maxWidth: 87.607, maxHeight: 87.607,
            child: quietAsset('connecting_glow', 87.607)),
        ),
        quietAsset('pause', 56.356),
      ],
    ),
  );
}

class LoadingMark extends StatefulWidget {
  const LoadingMark({super.key});
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
