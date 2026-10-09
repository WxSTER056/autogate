import 'package:flutter/material.dart';

class PulseMicButton extends StatefulWidget {
  final bool isListening;
  final double soundLevel;
  final VoidCallback onTap;

  const PulseMicButton({
    super.key,
    required this.isListening,
    required this.soundLevel,
    required this.onTap,
  });

  @override
  State<PulseMicButton> createState() => _PulseMicButtonState();
}

class _PulseMicButtonState extends State<PulseMicButton> with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.isListening) {
      _animController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant PulseMicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isListening && !_animController.isAnimating) {
      _animController.repeat(reverse: true);
    } else if (!widget.isListening && _animController.isAnimating) {
      _animController.stop();
      _animController.reset();
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _animController,
        builder: (context, child) {
          final scaleBonus = widget.isListening ? (_animController.value * 0.12) : 0.0;
          final glowRadius = widget.isListening ? (25.0 + _animController.value * 25.0) : 8.0;

          return Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.isListening
                      ? const Color(0xFF38BDF8).withValues(alpha: 0.55)
                      : Colors.black38,
                  blurRadius: glowRadius,
                  spreadRadius: widget.isListening ? 4.0 : 1.0,
                ),
                if (widget.isListening)
                  BoxShadow(
                    color: const Color(0xFF818CF8).withValues(alpha: 0.35),
                    blurRadius: glowRadius * 1.5,
                    spreadRadius: 8.0,
                  ),
              ],
            ),
            child: Transform.scale(
              scale: 1.0 + scaleBonus,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: widget.isListening
                        ? [const Color(0xFF0284C7), const Color(0xFF38BDF8)]
                        : [const Color(0xFF334155), const Color(0xFF1E293B)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                    color: widget.isListening ? const Color(0xFFBAE6FD) : Colors.white24,
                    width: 2.5,
                  ),
                ),
                child: Center(
                  child: Icon(
                    widget.isListening ? Icons.mic : Icons.mic_none_outlined,
                    color: Colors.white,
                    size: 48,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
