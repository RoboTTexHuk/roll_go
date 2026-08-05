import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class SimpleWebViewPage2 extends StatefulWidget {
  const SimpleWebViewPage2({Key? key}) : super(key: key);

  @override
  State<SimpleWebViewPage2> createState() => _SimpleWebViewPage2State();
}

class _SimpleWebViewPage2State extends State<SimpleWebViewPage2> {
  InAppWebViewController? _webViewController;
  double _progress = 0;

  // Канал для нативного per-screen лока ориентации.
  // iPad (Stage Manager / multitasking) может игнорировать чистый
  // Dart-лок через SystemChrome, поэтому дублируем нативным форсом
  // именно на время жизни этого экрана.
  static const MethodChannel _orientationChannel =
      MethodChannel('com.example.orientation');

  @override
  void initState() {
    super.initState();
    // Включаем только альбомную ориентацию
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // Форсим нативный лок именно для этого экрана (iOS/iPadOS)
    _orientationChannel.invokeMethod('lockLandscape').catchError((_) {});
  }

  @override
  void dispose() {
    // Возвращаем все ориентации при выходе с экрана
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // Снимаем нативный лок — остальное приложение снова свободно в ориентации
    _orientationChannel.invokeMethod('unlockLandscape').catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: Colors.black, // фон всего экрана
      body: SafeArea(
        child: Stack(
          children: [
            // WebView держим смонтированным всегда, чтобы не терять
            // состояние страницы при поворотах — просто перекрываем его
            // оверлеем, пока устройство не в landscape.
            Container(
              color: Colors.black, // фон внутри SafeArea
              child: InAppWebView(
                // стартовый URL
                initialUrlRequest: URLRequest(
                  url: WebUri('https://gameapp.retrogo.team/'),
                ),
                // базовые настройки
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
                onProgressChanged: (controller, progress) {
                  setState(() {
                    _progress = progress / 100.0;
                  });
                },
              ),
            ),
            if (!isLandscape) _buildRotatePrompt(),
          ],
        ),
      ),
    );
  }

  Widget _buildRotatePrompt() {
    return Container(
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(
              Icons.screen_rotation,
              color: Colors.white,
              size: 64,
            ),
            SizedBox(height: 16),
            Text(
              'Please rotate your device\nto continue',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ],
        ),
      ),
    );
  }
}
