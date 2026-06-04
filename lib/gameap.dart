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

  @override
  void initState() {
    super.initState();
    // Включаем только альбомную ориентацию
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // фон всего экрана
      body: SafeArea(
        child: Container(
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
      ),
    );
  }
}