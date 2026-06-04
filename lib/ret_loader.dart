import 'dart:math';
import 'package:flutter/material.dart';

/// Поместите изображения в assets:
///   assets/images/retro_bg.png   — фон (первый скрин)
///   assets/images/retro_logo.png — логотип (второй скрин)
///
/// Добавьте в pubspec.yaml:
///   flutter:
///     assets:
///       - assets/images/retro_bg.png
///       - assets/images/retro_logo.png



class RetroLoaderScreen extends StatefulWidget {
  const RetroLoaderScreen({super.key});

  @override
  State<RetroLoaderScreen> createState() => _RetroLoaderScreenState();
}

class _RetroLoaderScreenState extends State<RetroLoaderScreen>
    with TickerProviderStateMixin {
  late AnimationController _progressController;
  late AnimationController _glowController;
  late AnimationController _logoController;

  late Animation<double> _progressAnim;
  late Animation<double> _glowAnim;
  late Animation<double> _logoScaleAnim;
  late Animation<double> _logoOpacityAnim;

  @override
  void initState() {
    super.initState();

    // Логотип — плавное появление + лёгкий scale
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();

    _logoOpacityAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOut),
    );
    _logoScaleAnim = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );

    // Прогресс-бар — заполняется за 4 секунды
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..forward();

    _progressAnim = CurvedAnimation(
      parent: _progressController,
      curve: Curves.easeInOut,
    );

    // Пульсация свечения бара
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _glowAnim = Tween<double>(begin: 6.0, end: 18.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _progressController.dispose();
    _glowController.dispose();
    _logoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Фон ──────────────────────────────────────────────────────────
          Image.asset(
            'assets/retro_bg.jpg',
            fit: BoxFit.cover,
          ),

          // Лёгкий затемняющий оверлей, чтобы лого читалось лучше
          Container(
            color: Colors.black.withOpacity(0.25),
          ),

          // ── Логотип + прогресс-бар ────────────────────────────────────
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Логотип
                FadeTransition(
                  opacity: _logoOpacityAnim,
                  child: ScaleTransition(
                    scale: _logoScaleAnim,
                    child: Image.asset(
                      'assets/retro_logo.png',
                      width: MediaQuery.of(context).size.width * 0.62,
                    ),
                  ),
                ),

                const SizedBox(height: 40),

                // Прогресс-бар
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_progressAnim, _glowAnim]),
                    builder: (context, _) {
                      return _NeonProgressBar(
                        progress: _progressAnim.value,
                        glowRadius: _glowAnim.value,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Неоновый прогресс-бар
// ─────────────────────────────────────────────────────────────────────────────

class _NeonProgressBar extends StatelessWidget {
  const _NeonProgressBar({
    required this.progress,
    required this.glowRadius,
  });

  final double progress; // 0.0 – 1.0
  final double glowRadius;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _NeonBarPainter(progress: progress, glowRadius: glowRadius),
      size: const Size(double.infinity, 8),
    );
  }
}

class _NeonBarPainter extends CustomPainter {
  _NeonBarPainter({required this.progress, required this.glowRadius});

  final double progress;
  final double glowRadius;

  static const _barColor = Color(0xFF00E5FF);   // яркий cyan
  static const _trackColor = Color(0x33FFFFFF); // полупрозрачный белый трек

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      radius,
    );

    // Трек
    canvas.drawRRect(
      rrect,
      Paint()..color = _trackColor,
    );

    if (progress <= 0) return;

    final fillWidth = size.width * progress;

    // Основная заливка
    final fillRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, fillWidth, size.height),
      radius,
    );

    final fillPaint = Paint()
      ..shader = LinearGradient(
        colors: const [
          Color(0xFF80FFFF),
          Color(0xFF00E5FF),
          Color(0xFF0080FF),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, fillWidth, size.height));

    canvas.drawRRect(fillRRect, fillPaint);

    // Внешнее свечение
    canvas.drawRRect(
      fillRRect,
      Paint()
        ..color = _barColor.withOpacity(0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, glowRadius),
    );

    // Блик — яркая белая полоска в верхней трети
    final highlightRect = Rect.fromLTWH(
      4,
      size.height * 0.1,
      max(0, fillWidth - 8),
      size.height * 0.35,
    );
    if (highlightRect.width > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(highlightRect, radius),
        Paint()
          ..color = Colors.white.withOpacity(0.55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
  }

  @override
  bool shouldRepaint(_NeonBarPainter old) =>
      old.progress != progress || old.glowRadius != glowRadius;
}
