import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as retrogoMath;
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart'
    show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, SystemUiOverlayStyle, SystemChrome;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as retrogoTimezoneData;
import 'package:timezone/timezone.dart' as retrogoTimezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'external_links.dart';

// Если эти классы есть в main.dart – оставь импорт.
import 'main.dart' show MafiaHarbor, CaptainHarbor, BillHarbor;

// ============================================================================
// Retrogo инфраструктура (бывшая Dress Retro инфраструктура)
// ============================================================================

class RetrogoLogger {
  const RetrogoLogger();

  void retrogoLogInfo(Object retrogoMessage) =>
      debugPrint('[DressRetroLogger] $retrogoMessage');

  void retrogoLogWarn(Object retrogoMessage) =>
      debugPrint('[DressRetroLogger/WARN] $retrogoMessage');

  void retrogoLogError(Object retrogoMessage) =>
      debugPrint('[DressRetroLogger/ERR] $retrogoMessage');
}

class RetrogoVault {
  static final RetrogoVault sharedInstance = RetrogoVault._internalConstructor();
  RetrogoVault._internalConstructor();
  factory RetrogoVault() => sharedInstance;

  final RetrogoLogger retrogoLoggerInstance = const RetrogoLogger();
}

// ============================================================================
// Константы (статистика/кеш) — строки в кавычках не меняем
// ============================================================================

const String retrogoLoadedOnceKey = 'wheel_loaded_once';
const String retrogoStatEndpoint = 'https://getgame.portalroullete.bar/stat';
const String retrogoCachedFcmKey = 'wheel_cached_fcm';

// НОВОЕ: ключи для сохранения SafeArea и цвета в SharedPreferences
const String retrogoSafeAreaEnabledKey = 'safearea_enabled';
const String retrogoSafeAreaColorKey = 'safearea_color';

// ---------------- Bank constants (из первого main.dart) ----------------

const Set<String> kBankSchemes = {
  'td',
  'rbc',
  'cibc',
  'scotiabank',
  'bmo',
  'bmodigitalbanking',
  'desjardins',
  'tangerine',
  'nationalbank',
  'simplii',
  'dominotoronto',
};

const Set<String> kBankDomains = {
  'td.com',
  'tdcanadatrust.com',
  'easyweb.td.com',
  'rbc.com',
  'royalbank.com',
  'online.royalbank.com',
  'cibc.com',
  'cibc.ca',
  'online.cibc.com',
  'scotiabank.com',
  'scotiaonline.scotiabank.com',
  'bmo.com',
  'bmo.ca',
  'bmodigitalbanking.com',
  'desjardins.com',
  'tangerine.ca',
  'nbc.ca',
  'nationalbank.ca',
  'simplii.com',
  'simplii.ca',
  'dominotoronto.com',
  'dominobank.com',
};

// ============================================================================
// Утилиты: RetrogoKit (бывший DressRetroKit)
// ============================================================================

class RetrogoKit {
  static bool retrogoLooksLikeBareMail(Uri retrogoUri) {
    final String retrogoScheme = retrogoUri.scheme;
    if (retrogoScheme.isNotEmpty) return false;
    final String retrogoRaw = retrogoUri.toString();
    return retrogoRaw.contains('@') && !retrogoRaw.contains(' ');
  }

  static Uri retrogoToMailto(Uri retrogoUri) {
    final String retrogoFull = retrogoUri.toString();
    final List<String> retrogoBits = retrogoFull.split('?');
    final String retrogoWho = retrogoBits.first;
    final Map<String, String> retrogoQuery = retrogoBits.length > 1
        ? Uri.splitQueryString(retrogoBits[1])
        : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: retrogoWho,
      queryParameters: retrogoQuery.isEmpty ? null : retrogoQuery,
    );
  }

  static Uri retrogoGmailize(Uri retrogoMailUri) {
    final Map<String, String> retrogoQp = retrogoMailUri.queryParameters;
    final Map<String, String> retrogoParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (retrogoMailUri.path.isNotEmpty) 'to': retrogoMailUri.path,
      if ((retrogoQp['subject'] ?? '').isNotEmpty) 'su': retrogoQp['subject']!,
      if ((retrogoQp['body'] ?? '').isNotEmpty) 'body': retrogoQp['body']!,
      if ((retrogoQp['cc'] ?? '').isNotEmpty) 'cc': retrogoQp['cc']!,
      if ((retrogoQp['bcc'] ?? '').isNotEmpty) 'bcc': retrogoQp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', retrogoParams);
  }

  static String retrogoDigitsOnly(String retrogoSource) =>
      retrogoSource.replaceAll(RegExp(r'[^0-9+]'), '');
}

// ============================================================================
// Сервис открытия ссылок: RetrogoLinker (бывший DressRetroLinker)
// ============================================================================

class RetrogoLinker {
  static Future<bool> retrogoOpen(Uri retrogoUri) async {
    try {
      if (await launchUrl(
        retrogoUri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }
      return await launchUrl(
        retrogoUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (retrogoError) {
      debugPrint('DressRetroLinker error: $retrogoError; url=$retrogoUri');
      try {
        return await launchUrl(
          retrogoUri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }
}

// ============================================================================
// Bank helpers (из первого main.dart)
// ============================================================================

bool retrogoIsBankScheme(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  return kBankSchemes.contains(scheme);
}

bool retrogoIsBankDomain(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String bank in kBankDomains) {
    final String bankHost = bank.toLowerCase();
    if (host == bankHost || host.endsWith('.$bankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> retrogoOpenBank(Uri uri) async {
  try {
    if (retrogoIsBankScheme(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }

    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        retrogoIsBankDomain(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }
  } catch (e) {
    debugPrint('retrogoOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// FCM Background Handler
// ============================================================================

@pragma('vm:entry-point')
Future<void> retrogoFcmBackgroundHandler(RemoteMessage retrogoMessage) async {
  debugPrint("Spin ID: ${retrogoMessage.messageId}");
  debugPrint("Spin Data: ${retrogoMessage.data}");
}

// ============================================================================
// RetrogoDeviceProfile (бывший DressRetroDeviceProfile)
// ============================================================================

class RetrogoDeviceProfile {
  String? retrogoDeviceId;
  String? retrogoSessionId = 'wheel-one-off';
  String? retrogoPlatformKind;
  String? retrogoOsBuild;
  String? retrogoAppVersion;
  String? retrogoLocaleCode;
  String? retrogoTimezoneName;
  bool retrogoPushEnabled = true;

  // Новый UA из WebView
  String? retrogoBaseUserAgent;

  // Для SafeArea
  bool retrogoSafeAreaEnabled = false;
  String? retrogoSafeAreaColor;

  Future<void> retrogoInitialize() async {
    try {
      retrogoTimezoneData.initializeTimeZones();
    } catch (_) {}

    final DeviceInfoPlugin retrogoInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo retrogoAndroidInfo =
      await retrogoInfoPlugin.androidInfo;
      retrogoDeviceId = retrogoAndroidInfo.id;
      retrogoPlatformKind = 'android';
      retrogoOsBuild = retrogoAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo retrogoIosInfo = await retrogoInfoPlugin.iosInfo;
      retrogoDeviceId = retrogoIosInfo.identifierForVendor;
      retrogoPlatformKind = 'ios';
      retrogoOsBuild = retrogoIosInfo.systemVersion;
    }

    final PackageInfo retrogoPackageInfo = await PackageInfo.fromPlatform();
    retrogoAppVersion = retrogoPackageInfo.version;
    retrogoLocaleCode = Platform.localeName.split('_').first;
    retrogoTimezoneName = retrogoTimezone.local.name;
    retrogoSessionId = 'wheel-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> retrogoAsMap({String? retrogoFcmToken}) =>
      <String, dynamic>{
        'fcm_token': retrogoFcmToken ?? 'missing_token',
        'device_id': retrogoDeviceId ?? 'missing_id',
        'app_name': 'joiler',
        'instance_id': retrogoSessionId ?? 'missing_session',
        'platform': retrogoPlatformKind ?? 'missing_system',
        'os_version': retrogoOsBuild ?? 'missing_build',
        'app_version': retrogoAppVersion ?? 'missing_app',
        'language': retrogoLocaleCode ?? 'en',
        'timezone': retrogoTimezoneName ?? 'UTC',
        'push_enabled': retrogoPushEnabled,
        'fthcashier': 'true',
        'safearea': retrogoSafeAreaEnabled,
        'safearea_color': retrogoSafeAreaColor ?? '',
        'base_ua': retrogoBaseUserAgent ?? '',
      };
}

// ============================================================================
// AppsFlyer шпион: RetrogoSpy (бывший DressRetroSpy)
// ============================================================================

class RetrogoSpy {
  AppsFlyerOptions? retrogoOptions;
  AppsflyerSdk? retrogoSdk;

  String retrogoAppsFlyerUid = '';
  String retrogoAppsFlyerData = '';

  void retrogoStart({VoidCallback? retrogoOnUpdate}) {
    final AppsFlyerOptions retrogoOpts = AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6756072063',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    retrogoOptions = retrogoOpts;
    retrogoSdk = AppsflyerSdk(retrogoOpts);

    retrogoSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    retrogoSdk?.startSDK(
      onSuccess: () => RetrogoVault()
          .retrogoLoggerInstance
          .retrogoLogInfo('WheelSpy started'),
      onError: (retrogoCode, retrogoMsg) => RetrogoVault()
          .retrogoLoggerInstance
          .retrogoLogError('WheelSpy error $retrogoCode: $retrogoMsg'),
    );

    retrogoSdk?.onInstallConversionData((retrogoValue) {
      retrogoAppsFlyerData = retrogoValue.toString();
      retrogoOnUpdate?.call();
    });

    retrogoSdk?.getAppsFlyerUID().then((retrogoValue) {
      retrogoAppsFlyerUid = retrogoValue.toString();
      retrogoOnUpdate?.call();
    });
  }
}

// ============================================================================
// Мост для FCM токена: RetrogoFcmBridge (бывший DressRetroFcmBridge)
// ============================================================================

class RetrogoFcmBridge {
  final RetrogoLogger retrogoLog = const RetrogoLogger();
  String? retrogoToken;
  final List<void Function(String)> retrogoWaiters =
  <void Function(String)>[];

  String? get retrogoCurrentToken => retrogoToken;

  RetrogoFcmBridge() {
    const MethodChannel('com.example.fcm/token')
        .setMethodCallHandler((MethodCall retrogoCall) async {
      if (retrogoCall.method == 'setToken') {
        final String retrogoTokenString = retrogoCall.arguments as String;
        if (retrogoTokenString.isNotEmpty) {
          retrogoSetToken(retrogoTokenString);
        }
      }
    });

    retrogoRestoreToken();
  }

  Future<void> retrogoRestoreToken() async {
    try {
      final SharedPreferences retrogoPrefs =
      await SharedPreferences.getInstance();
      final String? retrogoCached = retrogoPrefs.getString(retrogoCachedFcmKey);
      if (retrogoCached != null && retrogoCached.isNotEmpty) {
        retrogoSetToken(retrogoCached, retrogoNotify: false);
      }
    } catch (_) {}
  }

  Future<void> retrogoPersistToken(String retrogoNewToken) async {
    try {
      final SharedPreferences retrogoPrefs =
      await SharedPreferences.getInstance();
      await retrogoPrefs.setString(retrogoCachedFcmKey, retrogoNewToken);
    } catch (_) {}
  }

  void retrogoSetToken(
      String retrogoNewToken, {
        bool retrogoNotify = true,
      }) {
    retrogoToken = retrogoNewToken;
    retrogoPersistToken(retrogoNewToken);
    if (retrogoNotify) {
      for (final void Function(String) retrogoCallback
      in List<void Function(String)>.from(retrogoWaiters)) {
        try {
          retrogoCallback(retrogoNewToken);
        } catch (retrogoErr) {
          retrogoLog.retrogoLogWarn('fcm waiter error: $retrogoErr');
        }
      }
      retrogoWaiters.clear();
    }
  }

  Future<void> retrogoWaitForToken(
      Function(String retrogoTokenValue) retrogoOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((retrogoToken ?? '').isNotEmpty) {
        retrogoOnToken(retrogoToken!);
        return;
      }

      retrogoWaiters.add(retrogoOnToken);
    } catch (retrogoErr) {
      retrogoLog.retrogoLogError('wheelWaitToken error: $retrogoErr');
    }
  }
}

// ============================================================================
// RetrogoLoader (новый лоадер)
// ============================================================================

class RetrogoLoader extends StatefulWidget {
  const RetrogoLoader({Key? key}) : super(key: key);

  @override
  State<RetrogoLoader> createState() => _RetrogoLoaderState();
}

class _RetrogoLoaderState extends State<RetrogoLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController retrogoController;

  static const Color retrogoBackgroundColor = Color(0xFF05071B);

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));
    retrogoController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    retrogoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: retrogoBackgroundColor,
      child: AnimatedBuilder(
        animation: retrogoController,
        builder: (BuildContext context, Widget? child) {
          final double retrogoPhase =
              retrogoController.value * 2 * retrogoMath.pi;
          return CustomPaint(
            painter: RetrogoLoaderPainter(
              retrogoPhase: retrogoPhase,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class RetrogoLoaderPainter extends CustomPainter {
  final double retrogoPhase;

  RetrogoLoaderPainter({
    required this.retrogoPhase,
  });

  @override
  void paint(Canvas retrogoCanvas, Size retrogoSize) {
    final double retrogoWidth = retrogoSize.width;
    final double retrogoHeight = retrogoSize.height;

    final Paint retrogoBackgroundPaint = Paint()
      ..color = const Color(0xFF05071B)
      ..style = PaintingStyle.fill;
    retrogoCanvas.drawRect(Offset.zero & retrogoSize, retrogoBackgroundPaint);

    final double retrogoPulse = (retrogoMath.sin(retrogoPhase) + 1) / 2;

    final Paint retrogoCirclePaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.red.withOpacity(0.14 + 0.16 * retrogoPulse),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(retrogoWidth * 0.5, retrogoHeight * 0.45),
          radius: retrogoHeight * (0.4 + 0.15 * retrogoPulse),
        ),
      );

    retrogoCanvas.drawCircle(
      Offset(retrogoWidth * 0.5, retrogoHeight * 0.45),
      retrogoHeight * (0.4 + 0.15 * retrogoPulse),
      retrogoCirclePaint,
    );

    final Paint retrogoOuterPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.redAccent.withOpacity(0.10 + 0.10 * (1 - retrogoPulse)),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(retrogoWidth * 0.5, retrogoHeight * 0.45),
          radius: retrogoHeight * (0.55 + 0.10 * (1 - retrogoPulse)),
        ),
      );
    retrogoCanvas.drawCircle(
      Offset(retrogoWidth * 0.5, retrogoHeight * 0.45),
      retrogoHeight * (0.55 + 0.10 * (1 - retrogoPulse)),
      retrogoOuterPaint,
    );

    final double retrogoBaseSize = retrogoWidth * 0.35;
    final double retrogoFontSize =
        retrogoBaseSize + retrogoPulse * (retrogoBaseSize * 0.15);

    const String retrogoLetter = 'N';
    const String retrogoWord = 'CUP';

    final TextPainter retrogoLetterPainter = TextPainter(
      text: TextSpan(
        text: retrogoLetter,
        style: TextStyle(
          fontSize: retrogoFontSize,
          fontWeight: FontWeight.w900,
          color: Colors.red.shade600,
          letterSpacing: 4,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.8),
              blurRadius: 22 + 18 * retrogoPulse,
              offset: const Offset(0, 0),
            ),
            Shadow(
              color: Colors.black.withOpacity(0.8),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: retrogoWidth);

    final double retrogoLetterX =
        (retrogoWidth - retrogoLetterPainter.width) / 2;
    final double retrogoLetterY =
        (retrogoHeight - retrogoLetterPainter.height) / 2;

    final Offset retrogoLetterOffset = Offset(retrogoLetterX, retrogoLetterY);

    final Rect retrogoLetterRect = Rect.fromCenter(
      center: Offset(retrogoWidth / 2, retrogoHeight / 2),
      width: retrogoLetterPainter.width * 1.4,
      height: retrogoLetterPainter.height * 1.6,
    );

    final Paint retrogoGlowPaint = Paint()
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        28 + 24 * retrogoPulse,
      )
      ..color = Colors.red.withOpacity(0.7 + 0.2 * retrogoPulse);

    retrogoCanvas.saveLayer(retrogoLetterRect, retrogoGlowPaint);
    retrogoLetterPainter.paint(retrogoCanvas, retrogoLetterOffset);
    retrogoCanvas.restore();

    retrogoLetterPainter.paint(retrogoCanvas, retrogoLetterOffset);

    final double retrogoCupFontSize = retrogoWidth * 0.11;

    final TextPainter retrogoCupPainterReal = TextPainter(
      text: TextSpan(
        text: retrogoWord,
        style: TextStyle(
          fontSize: retrogoCupFontSize,
          fontWeight: FontWeight.w600,
          color: Colors.red.shade100.withOpacity(0.95),
          letterSpacing: 5,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.7),
              blurRadius: 12 + 10 * retrogoPulse,
              offset: const Offset(0, 0),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: retrogoWidth);

    final double retrogoCupX =
        (retrogoWidth - retrogoCupPainterReal.width) / 2;
    final double retrogoCupY =
        retrogoLetterY + retrogoLetterPainter.height + retrogoHeight * 0.03;

    final Offset retrogoCupOffset = Offset(retrogoCupX, retrogoCupY);
    retrogoCupPainterReal.paint(retrogoCanvas, retrogoCupOffset);
  }

  @override
  bool shouldRepaint(covariant RetrogoLoaderPainter retrogoOldDelegate) =>
      retrogoOldDelegate.retrogoPhase != retrogoPhase;
}

// ============================================================================
// Статистика (retrogoFinalUrl / retrogoPostStat) — строки не меняем
// ============================================================================

Future<String> retrogoFinalUrl(
    String retrogoStartUrl, {
      int retrogoMaxHops = 10,
    }) async {
  final HttpClient retrogoClient = HttpClient();

  try {
    Uri retrogoCurrentUri = Uri.parse(retrogoStartUrl);

    for (int retrogoI = 0; retrogoI < retrogoMaxHops; retrogoI++) {
      final HttpClientRequest retrogoRequest =
      await retrogoClient.getUrl(retrogoCurrentUri);
      retrogoRequest.followRedirects = false;
      final HttpClientResponse retrogoResponse =
      await retrogoRequest.close();

      if (retrogoResponse.isRedirect) {
        final String? retrogoLoc =
        retrogoResponse.headers.value(HttpHeaders.locationHeader);
        if (retrogoLoc == null || retrogoLoc.isEmpty) break;

        final Uri retrogoNextUri = Uri.parse(retrogoLoc);
        retrogoCurrentUri = retrogoNextUri.hasScheme
            ? retrogoNextUri
            : retrogoCurrentUri.resolveUri(retrogoNextUri);
        continue;
      }

      return retrogoCurrentUri.toString();
    }

    return retrogoCurrentUri.toString();
  } catch (retrogoError) {
    debugPrint('wheelFinalUrl error: $retrogoError');
    return retrogoStartUrl;
  } finally {
    retrogoClient.close(force: true);
  }
}

Future<void> retrogoPostStat({
  required String retrogoEvent,
  required int retrogoTimeStart,
  required String retrogoUrl,
  required int retrogoTimeFinish,
  required String retrogoAppSid,
  int? retrogoFirstPageTs,
}) async {
  try {
    final String retrogoResolvedUrl = await retrogoFinalUrl(retrogoUrl);
    final Map<String, dynamic> retrogoPayload = <String, dynamic>{
      'event': retrogoEvent,
      'timestart': retrogoTimeStart,
      'timefinsh': retrogoTimeFinish,
      'url': retrogoResolvedUrl,
      'appleID': '6755681349',
      'open_count': '$retrogoAppSid/$retrogoTimeStart',
    };

    debugPrint('wheelStat $retrogoPayload');

    final http.Response retrogoResp = await http.post(
      Uri.parse('$retrogoStatEndpoint/$retrogoAppSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(retrogoPayload),
    );

    debugPrint('wheelStat resp=${retrogoResp.statusCode} body=${retrogoResp.body}');
  } catch (retrogoError) {
    debugPrint('wheelPostStat error: $retrogoError');
  }
}

// ============================================================================
// WebView-экран: RetrogoTableView (бывший DressRetroTableView)
// SafeArea + SafeArea color + localStorage подхватываются из SharedPreferences
// ============================================================================

class RetrogoTableView extends StatefulWidget with WidgetsBindingObserver {
  String retrogoStartingUrl;
  RetrogoTableView(this.retrogoStartingUrl, {super.key});

  @override
  State<RetrogoTableView> createState() =>
      _RetrogoTableViewState(retrogoStartingUrl);
}

class _RetrogoTableViewState extends State<RetrogoTableView>
    with WidgetsBindingObserver {
  _RetrogoTableViewState(this.retrogoCurrentUrl);

  final RetrogoVault retrogoVaultInstance = RetrogoVault();

  late InAppWebViewController retrogoWebViewController;
  String? retrogoPushToken;
  final RetrogoDeviceProfile retrogoDeviceProfileInstance =
  RetrogoDeviceProfile();
  final RetrogoSpy retrogoSpyInstance = RetrogoSpy();

  bool retrogoOverlayBusy = false;
  String retrogoCurrentUrl;
  DateTime? retrogoLastPausedAt;

  bool retrogoLoadedOnceSent = false;
  int? retrogoFirstPageTimestamp;
  int retrogoStartLoadTimestamp = 0;

  // --------- Социальные / внешние хосты / схемы ---------

  final Set<String> retrogoExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  final Set<String> retrogoExternalSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'bnl',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
  };

  final Set<String> retrogoSpecialSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  // --------- UserAgent + SafeArea ---------

  String? _baseUserAgent;
  String _currentUserAgent = '';
  String? _serverUserAgent;
  bool _isInGoogleAuth = false;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = Colors.black;

  // --------- POPUP (window.open) ---------

  InAppWebViewController? _popupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;
  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    FirebaseMessaging.onBackgroundMessage(retrogoFcmBackgroundHandler);

    retrogoFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;

    // 1) SafeArea state (enabled + color) подхватываем из SharedPreferences
    _loadSafeAreaFromPrefs();

    // 2) Push
    retrogoInitPushAndGetToken();

    // 3) Профиль устройства -> localStorage + SharedPreferences (app_data)
    retrogoDeviceProfileInstance.retrogoInitialize().then((_) async {
      if (!mounted) return;
      await _updateLocalStorage();
    });

    // 4) FCM + AppsFlyer
    retrogoWireForegroundPushHandlers();
    retrogoBindPlatformNotificationTap();
    retrogoSpyInstance.retrogoStart(retrogoOnUpdate: () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState retrogoState) {
    if (retrogoState == AppLifecycleState.paused) {
      retrogoLastPausedAt = DateTime.now();
    }
    if (retrogoState == AppLifecycleState.resumed) {
      if (Platform.isIOS && retrogoLastPausedAt != null) {
        final DateTime retrogoNow = DateTime.now();
        final Duration retrogoDrift =
        retrogoNow.difference(retrogoLastPausedAt!);
        if (retrogoDrift > const Duration(minutes: 25)) {
          retrogoForceReloadToLobby();
        }
      }
      retrogoLastPausedAt = null;
    }
  }

  void retrogoForceReloadToLobby() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration retrogoDuration) {
      if (!mounted) return;
      // здесь можно вернуть в MafiaHarbor/CaptainHarbor/BillHarbor при необходимости
    });
  }

  // --------------------------------------------------------------------------
  // Push / FCM
  // --------------------------------------------------------------------------

  void retrogoWireForegroundPushHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage retrogoMsg) {
      if (retrogoMsg.data['uri'] != null) {
        retrogoNavigateTo(retrogoMsg.data['uri'].toString());
      } else {
        retrogoReturnToCurrentUrl();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage retrogoMsg) {
      if (retrogoMsg.data['uri'] != null) {
        retrogoNavigateTo(retrogoMsg.data['uri'].toString());
      } else {
        retrogoReturnToCurrentUrl();
      }
    });
  }

  void retrogoNavigateTo(String retrogoNewUrl) async {
    await retrogoWebViewController.loadUrl(
      urlRequest: URLRequest(url: WebUri(retrogoNewUrl)),
    );
  }

  void retrogoReturnToCurrentUrl() async {
    Future<void>.delayed(const Duration(seconds: 3), () {
      retrogoWebViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(retrogoCurrentUrl)),
      );
    });
  }

  Future<void> retrogoInitPushAndGetToken() async {
    final FirebaseMessaging retrogoFm = FirebaseMessaging.instance;
    await retrogoFm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    retrogoPushToken = await retrogoFm.getToken();
  }

  // --------------------------------------------------------------------------
  // Привязка канала: тап по уведомлению из native
  // --------------------------------------------------------------------------

  void retrogoBindPlatformNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall retrogoCall) async {
      if (retrogoCall.method == "onNotificationTap") {
        final Map<String, dynamic> retrogoPayload =
        Map<String, dynamic>.from(retrogoCall.arguments);
        debugPrint("URI from platform tap: ${retrogoPayload['uri']}");
        final String? retrogoUriString = retrogoPayload["uri"]?.toString();
        if (retrogoUriString != null &&
            !retrogoUriString.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext retrogoContext) =>
                  RetrogoTableView(retrogoUriString),
            ),
                (Route<dynamic> retrogoRoute) => false,
          );
        }
      }
    });
  }

  // --------------------------------------------------------------------------
  // localStorage + SharedPreferences: профиль устройства
  // --------------------------------------------------------------------------

  /// Обновляем app_data в localStorage И синхронно сохраняем JSON в SharedPreferences
  Future<void> _updateLocalStorage() async {
    try {
      final Map<String, dynamic> data = retrogoDeviceProfileInstance.retrogoAsMap(
        retrogoFcmToken: retrogoPushToken,
      );

      final String json = jsonEncode(data);

      // 1) В localStorage WebView
      await retrogoWebViewController.evaluateJavascript(
        source: "localStorage.setItem('app_data', JSON.stringify($json));",
      );

      // 2) В SharedPreferences (чтобы при следующем запуске можно было восстановить)
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_data', json);

      retrogoVaultInstance.retrogoLoggerInstance.retrogoLogInfo(
          'app_data saved to localStorage & SharedPreferences: $json');
    } catch (e, st) {
      retrogoVaultInstance.retrogoLoggerInstance
          .retrogoLogError('updateLocalStorage error: $e\n$st');
    }
  }

  /// Восстанавливаем app_data из SharedPreferences обратно в localStorage
  Future<void> _restoreAppDataFromPrefsToLocalStorage() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? savedJson = prefs.getString('app_data');
      if (savedJson == null || savedJson.isEmpty) {
        return;
      }

      final String js =
          "localStorage.setItem('app_data', JSON.stringify($savedJson));";

      await retrogoWebViewController.evaluateJavascript(source: js);

      retrogoVaultInstance.retrogoLoggerInstance.retrogoLogInfo(
          'app_data restored from SharedPreferences to localStorage: $savedJson');
    } catch (e, st) {
      retrogoVaultInstance.retrogoLoggerInstance.retrogoLogError(
          '_restoreAppDataFromPrefsToLocalStorage error: $e\n$st');
    }
  }

  // --------------------------------------------------------------------------
  // UserAgent / SafeArea helpers
  // --------------------------------------------------------------------------

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google');
  }

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await retrogoWebViewController.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          retrogoDeviceProfileInstance.retrogoBaseUserAgent = _baseUserAgent;
          retrogoVaultInstance.retrogoLoggerInstance
              .retrogoLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        retrogoVaultInstance.retrogoLoggerInstance
            .retrogoLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      retrogoVaultInstance.retrogoLoggerInstance
          .retrogoLogWarn('Base User-Agent is null, skip UA update');
      return;
    }

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = _baseUserAgent!;
    }

    _serverUserAgent = newUa;
    retrogoVaultInstance.retrogoLoggerInstance
        .retrogoLogInfo('Server UA calculated: $_serverUserAgent');
  }

  Future<void> _updateUserAgentFromServerPayload(
      Map<dynamic, dynamic> root) async {
    String? fullua;
    String? uatail;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['fullua'] != null &&
          content['fullua'].toString().trim().isNotEmpty) {
        fullua = content['fullua'].toString().trim();
      }
      if (content['uatail'] != null &&
          content['uatail'].toString().trim().isNotEmpty) {
        uatail = content['uatail'].toString().trim();
      }
    }

    if (fullua == null &&
        root['fullua'] != null &&
        root['fullua'].toString().trim().isNotEmpty) {
      fullua = root['fullua'].toString().trim();
    }
    if (uatail == null &&
        root['uatail'] != null &&
        root['uatail'].toString().trim().isNotEmpty) {
      uatail = root['uatail'].toString().trim();
    }

    if (uatail == null) {
      final dynamic adata = root['adata'];
      if (adata is Map &&
          adata['uatail'] != null &&
          adata['uatail'].toString().trim().isNotEmpty) {
        uatail = adata['uatail'].toString().trim();
      }
    }

    await _applyUserAgent(fullua: fullua, uatail: uatail);
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (_isInGoogleAuth) {
      retrogoVaultInstance.retrogoLoggerInstance.retrogoLogInfo(
          'Skip normal UA apply because we are in Google auth');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) return;

    try {
      await retrogoWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      debugPrint('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      retrogoVaultInstance.retrogoLoggerInstance
          .retrogoLogError('Error while setting UA "$targetUa": $e');
    }
  }

  Future<void> _addRandomToUserAgentForGoogle() async {
    const String targetUa = 'random';
    if (_currentUserAgent == targetUa && _isInGoogleAuth) return;

    try {
      await retrogoWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      _isInGoogleAuth = true;
      debugPrint('[UA] GOOGLE RANDOM USER AGENT: $_currentUserAgent');
    } catch (e) {
      retrogoVaultInstance.retrogoLoggerInstance
          .retrogoLogError('Error setting RANDOM UA for Google: $e');
    }
  }

  Future<void> _restoreUserAgentAfterGoogleIfNeeded() async {
    if (!_isInGoogleAuth) return;
    _isInGoogleAuth = false;
    await _applyNormalUserAgentIfNeeded();
  }

  // Хелпер для парсинга HEX‑цвета (общий для SafeArea и prefs)
  Color _parseHexColor(String hex, {Color fallback = const Color(0xFF1A1A22)}) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) value = 'FF$value';
    final intColor = int.tryParse(value, radix: 16);
    if (intColor == null) return fallback;
    return Color(intColor);
  }

  // НОВОЕ: загрузка SafeArea из SharedPreferences при старте
  Future<void> _loadSafeAreaFromPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool enabled = prefs.getBool(retrogoSafeAreaEnabledKey) ?? false;
      final String colorHex = prefs.getString(retrogoSafeAreaColorKey) ?? '';

      Color bg = Colors.black;
      if (enabled) {
        if (colorHex.isNotEmpty) {
          bg = _parseHexColor(colorHex, fallback: const Color(0xFF1A1A22));
        } else {
          bg = const Color(0xFF1A1A22);
        }
      }

      if (!mounted) return;

      setState(() {
        _safeAreaEnabled = enabled;
        _safeAreaBackgroundColor = bg;
        retrogoDeviceProfileInstance.retrogoSafeAreaEnabled = enabled;
        retrogoDeviceProfileInstance.retrogoSafeAreaColor =
        enabled ? (colorHex.isNotEmpty ? colorHex : '#1A1A22') : '';
      });

      retrogoVaultInstance.retrogoLoggerInstance.retrogoLogInfo(
          'SafeArea loaded from prefs: enabled=$enabled, color="$colorHex"');
    } catch (e, st) {
      retrogoVaultInstance.retrogoLoggerInstance
          .retrogoLogError('_loadSafeAreaFromPrefs error: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    bool? safearea;
    String? bgLightHex;
    String? bgDarkHex;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['safearea'] != null) {
        final dynamic raw = content['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (content['safearea_color'] != null &&
          content['safearea_color'].toString().trim().isNotEmpty) {
        bgLightHex = content['safearea_color'].toString().trim();
        bgDarkHex = bgLightHex;
      }
    }

    final dynamic adata = root['adata'];
    if (adata is Map) {
      if (safearea == null && adata['safearea'] != null) {
        final dynamic raw = adata['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (adata['bgsareaw'] != null &&
          adata['bgsareaw'].toString().trim().isNotEmpty) {
        bgLightHex = adata['bgsareaw'].toString().trim();
      }
      if (adata['bgsareab'] != null &&
          adata['bgsareab'].toString().trim().isNotEmpty) {
        bgDarkHex = adata['bgsareab'].toString().trim();
      }
    }

    if (safearea == null && root['safearea'] != null) {
      final dynamic raw = root['safearea'];
      if (raw is bool) {
        safearea = raw;
      } else if (raw is String) {
        final String v = raw.toLowerCase().trim();
        if (v == 'true' || v == '1' || v == 'yes') safearea = true;
        if (v == 'false' || v == '0' || v == 'no') safearea = false;
      } else if (raw is num) {
        safearea = raw != 0;
      }
    }

    if (safearea == null) return;

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    Color background = safearea ? const Color(0xFF1A1A22) : Colors.black;

    if (safearea && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex, fallback: const Color(0xFF1A1A22));
    }

    setState(() {
      _safeAreaEnabled = safearea!;
      _safeAreaBackgroundColor = background;
      retrogoDeviceProfileInstance.retrogoSafeAreaEnabled = safearea;
      retrogoDeviceProfileInstance.retrogoSafeAreaColor =
      safearea ? (chosenHex ?? '#1A1A22') : '';
    });

    // НОВОЕ: сохраняем SafeArea в SharedPreferences при каждом обновлении
    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool(retrogoSafeAreaEnabledKey, safearea!);
        await prefs.setString(
          retrogoSafeAreaColorKey,
          retrogoDeviceProfileInstance.retrogoSafeAreaColor ?? '',
        );
        retrogoVaultInstance.retrogoLoggerInstance.retrogoLogInfo(
          'SafeArea saved to prefs: enabled=$safearea, color="${retrogoDeviceProfileInstance.retrogoSafeAreaColor}"',
        );
      } catch (e, st) {
        retrogoVaultInstance.retrogoLoggerInstance
            .retrogoLogError('Error saving SafeArea to prefs: $e\n$st');
      }
    }();
  }

  // --------------------------------------------------------------------------
  // POPUP helpers
  // --------------------------------------------------------------------------

  InAppWebViewSettings _popupSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      useOnNavigationResponse: true,
      supportMultipleWindows: true,
      transparentBackground: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  void _openPopup(CreateWindowAction req, {String? urlString}) {
    setState(() {
      _popupCreateAction = req;
      _popupUrl = (urlString != null && urlString.isNotEmpty)
          ? urlString
          : req.request.url?.toString();
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      _popupWebViewController = null;
    });
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = _popupWebViewController;
    if (c == null) {
      if (_popupCanGoBack && mounted) {
        setState(() {
          _popupCanGoBack = false;
        });
      }
      return;
    }
    try {
      final bool can = await c.canGoBack();
      if (!mounted) return;
      if (can != _popupCanGoBack) {
        setState(() {
          _popupCanGoBack = can;
        });
      }
    } catch (_) {}
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = _popupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          _refreshPopupCanGoBack();
        });
      } else {
        _closePopup();
      }
    } catch (_) {
      _closePopup();
    }
  }

  Widget _buildPopupOverlay() {
    if (!_isPopupVisible || (_popupUrl == null && _popupCreateAction == null)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Container(
                color: Colors.black,
                height: 48,
                child: Row(
                  children: [
                    if (_popupCanGoBack)
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: _handlePopupBackPressed,
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: _closePopup,
                      ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null && _popupUrl != null)
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupSettings(),
                onWebViewCreated: (InAppWebViewController controller) async {
                  _popupWebViewController = controller;
                },
                onLoadStart: (controller, uri) async {
                  if (uri != null) {
                    setState(() {
                      _popupCurrentUrl = uri.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStop: (controller, uri) async {
                  if (uri != null) {
                    setState(() {
                      _popupCurrentUrl = uri.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory:
                    (controller, url, isReload) async {
                  if (url != null) {
                    setState(() {
                      _popupCurrentUrl = url.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction nav,
                    ) async {
                  final Uri? uri = nav.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  // Telegram / Wallet — сразу во внешний браузер
                  if (await retrogoHandleForcedExternal(uri)) {
                    return NavigationActionPolicy.CANCEL;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (RetrogoKit.retrogoLooksLikeBareMail(uri)) {
                    final Uri mailto = RetrogoKit.retrogoToMailto(uri);
                    await RetrogoLinker.retrogoOpen(
                      RetrogoKit.retrogoGmailize(mailto),
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await RetrogoLinker.retrogoOpen(
                      RetrogoKit.retrogoGmailize(uri),
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (retrogoIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          retrogoIsBankDomain(uri))) {
                    await retrogoOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  _closePopup();
                },
                onNavigationResponse: (controller, navigationResponse) async {
                  // Apple Wallet (.pkpass) по MIME — сразу во внешний браузер
                  final URLResponse? resp = navigationResponse.response;
                  if (retrogoIsWalletMime(resp?.mimeType)) {
                    final Uri? walletUri = resp?.url;
                    if (walletUri != null) await retrogoOpenWalletExternal(walletUri);
                    return NavigationResponseAction.CANCEL;
                  }
                  return NavigationResponseAction.ALLOW;
                },
                onDownloadStartRequest: (controller, req) async {
                  await RetrogoLinker.retrogoOpen(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    retrogoBindPlatformNotificationTap();

    final bool retrogoIsDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;

    final Color bgColor = _safeAreaEnabled
        ? _safeAreaBackgroundColor
        : (retrogoIsDark ? Colors.black : Colors.white);

    final Widget webView = InAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        disableDefaultErrorPage: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        allowsPictureInPictureMediaPlayback: true,
        useOnDownloadStart: true,
        javaScriptCanOpenWindowsAutomatically: true,
        useShouldOverrideUrlLoading: true,
        useOnNavigationResponse: true,
        supportMultipleWindows: true,
      ),
      initialUrlRequest: URLRequest(
        url: WebUri(retrogoCurrentUrl),
      ),
      onWebViewCreated: (InAppWebViewController retrogoController) async {
        retrogoWebViewController = retrogoController;

        // Инициализация UA
        try {
          final ua = await retrogoController.evaluateJavascript(
            source: "navigator.userAgent",
          );
          if (ua is String && ua.trim().isNotEmpty) {
            _baseUserAgent = ua.trim();
            _currentUserAgent = _baseUserAgent!;
            retrogoDeviceProfileInstance.retrogoBaseUserAgent = _baseUserAgent;
            debugPrint('[UA] INITIAL: $_baseUserAgent');
          }
        } catch (e) {
          retrogoVaultInstance.retrogoLoggerInstance
              .retrogoLogWarn('Failed to read navigator.userAgent: $e');
        }

        await _applyNormalUserAgentIfNeeded();

        // После создания WebView — актуализируем localStorage
        await _updateLocalStorage();

        // Через 6 секунд после открытия экрана — восстановление app_data из SharedPreferences
        Future<void>.delayed(const Duration(seconds: 6), () async {
          if (!mounted) return;
          await _restoreAppDataFromPrefsToLocalStorage();
        });

        retrogoWebViewController.addJavaScriptHandler(
          handlerName: 'onServerResponse',
          callback: (List<dynamic> retrogoArgs) {
            retrogoVaultInstance.retrogoLoggerInstance
                .retrogoLogInfo("JS Args: $retrogoArgs");

            try {
              dynamic first = retrogoArgs.isNotEmpty ? retrogoArgs[0] : null;

              if (first is List && first.isNotEmpty) {
                first = first.first;
              }

              if (first is Map) {
                final Map<dynamic, dynamic> root = first;

                // safearea + userAgent из сервера
                _updateSafeAreaFromServerPayload(root);
                _updateUserAgentFromServerPayload(root);
                _applyNormalUserAgentIfNeeded();

                // При каждом ответе сервера можно обновлять localStorage
                _updateLocalStorage();
              }

              try {
                return retrogoArgs.reduce(
                      (dynamic retrogoV, dynamic retrogoE) => retrogoV + retrogoE,
                );
              } catch (_) {
                return retrogoArgs.toString();
              }
            } catch (e) {
              return retrogoArgs.toString();
            }
          },
        );
      },
      onLoadStart: (
          InAppWebViewController retrogoController,
          Uri? retrogoUri,
          ) async {
        retrogoStartLoadTimestamp = DateTime.now().millisecondsSinceEpoch;

        if (retrogoUri != null &&
            (retrogoIsTelegramUri(retrogoUri) ||
                retrogoIsWalletUri(retrogoUri))) {
          try {
            await retrogoController.stopLoading();
          } catch (_) {}
          await retrogoHandleForcedExternal(retrogoUri);
          return;
        }

        if (retrogoUri != null) {
          if (_isGoogleUrl(retrogoUri)) {
            await _addRandomToUserAgentForGoogle();
          } else {
            await _restoreUserAgentAfterGoogleIfNeeded();
            await _applyNormalUserAgentIfNeeded();
          }

          if (RetrogoKit.retrogoLooksLikeBareMail(retrogoUri)) {
            try {
              await retrogoController.stopLoading();
            } catch (_) {}
            final Uri retrogoMailto = RetrogoKit.retrogoToMailto(retrogoUri);
            await RetrogoLinker.retrogoOpen(
              RetrogoKit.retrogoGmailize(retrogoMailto),
            );
            return;
          }

          // банки
          if (retrogoIsBankScheme(retrogoUri) ||
              ((retrogoUri.scheme == 'http' || retrogoUri.scheme == 'https') &&
                  retrogoIsBankDomain(retrogoUri))) {
            try {
              await retrogoController.stopLoading();
            } catch (_) {}
            await retrogoOpenBank(retrogoUri);
            return;
          }

          final String retrogoScheme = retrogoUri.scheme.toLowerCase();
          if (retrogoScheme != 'http' && retrogoScheme != 'https') {
            try {
              await retrogoController.stopLoading();
            } catch (_) {}
          }
        }
      },
      onLoadStop: (
          InAppWebViewController retrogoController,
          Uri? retrogoUri,
          ) async {
        await retrogoController.evaluateJavascript(
          source: "console.log('Hello from Roulette JS!');",
        );

        setState(() {
          retrogoCurrentUrl = retrogoUri?.toString() ?? retrogoCurrentUrl;
        });

        await _restoreUserAgentAfterGoogleIfNeeded();
        await _applyNormalUserAgentIfNeeded();

        // После полной загрузки страницы обновляем localStorage
        await _updateLocalStorage();

        // И сразу тянем app_data из SharedPreferences в localStorage
        await _restoreAppDataFromPrefsToLocalStorage();

        Future<void>.delayed(const Duration(seconds: 20), () {
          retrogoSendLoadedOnce();
        });
      },
      shouldOverrideUrlLoading: (
          InAppWebViewController retrogoController,
          NavigationAction retrogoNav,
          ) async {
        final Uri? retrogoUri = retrogoNav.request.url;
        if (retrogoUri == null) {
          return NavigationActionPolicy.ALLOW;
        }

        // Telegram / Wallet — сразу во внешний браузер
        if (await retrogoHandleForcedExternal(retrogoUri)) {
          return NavigationActionPolicy.CANCEL;
        }

        if (_isGoogleUrl(retrogoUri)) {
          await _addRandomToUserAgentForGoogle();
        } else {
          await _restoreUserAgentAfterGoogleIfNeeded();
          await _applyNormalUserAgentIfNeeded();
        }

        if (RetrogoKit.retrogoLooksLikeBareMail(retrogoUri)) {
          final Uri retrogoMailto = RetrogoKit.retrogoToMailto(retrogoUri);
          await RetrogoLinker.retrogoOpen(
            RetrogoKit.retrogoGmailize(retrogoMailto),
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String retrogoScheme = retrogoUri.scheme.toLowerCase();

        if (retrogoScheme == 'mailto') {
          await RetrogoLinker.retrogoOpen(
            RetrogoKit.retrogoGmailize(retrogoUri),
          );
          return NavigationActionPolicy.CANCEL;
        }

        if (retrogoIsBankScheme(retrogoUri) ||
            ((retrogoScheme == 'http' || retrogoScheme == 'https') &&
                retrogoIsBankDomain(retrogoUri))) {
          await retrogoOpenBank(retrogoUri);
          return NavigationActionPolicy.CANCEL;
        }

        if (retrogoScheme == 'tel') {
          await launchUrl(
            retrogoUri,
            mode: LaunchMode.externalApplication,
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String retrogoHost = retrogoUri.host.toLowerCase();
        final bool retrogoIsSocial = retrogoHost.endsWith('facebook.com') ||
            retrogoHost.endsWith('instagram.com') ||
            retrogoHost.endsWith('twitter.com') ||
            retrogoHost.endsWith('x.com');

        if (retrogoIsSocial) {
          await RetrogoLinker.retrogoOpen(retrogoUri);
          return NavigationActionPolicy.CANCEL;
        }

        if (retrogoIsExternalDestination(retrogoUri)) {
          final Uri retrogoMapped = retrogoMapExternalToHttp(retrogoUri);
          await RetrogoLinker.retrogoOpen(retrogoMapped);
          return NavigationActionPolicy.CANCEL;
        }

        if (retrogoScheme != 'http' && retrogoScheme != 'https') {
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
      onNavigationResponse: (controller, navigationResponse) async {
        // Apple Wallet (.pkpass) по MIME — сразу во внешний браузер
        final URLResponse? resp = navigationResponse.response;
        if (retrogoIsWalletMime(resp?.mimeType)) {
          final Uri? walletUri = resp?.url;
          if (walletUri != null) await retrogoOpenWalletExternal(walletUri);
          return NavigationResponseAction.CANCEL;
        }
        return NavigationResponseAction.ALLOW;
      },
      onDownloadStartRequest: (controller, req) async {
        // Скачивания (в т.ч. .pkpass) — во внешний браузер
        await launchUrl(req.url, mode: LaunchMode.externalApplication);
      },
      onCreateWindow: (
          InAppWebViewController retrogoController,
          CreateWindowAction retrogoReq,
          ) async {
        final Uri? retrogoUrl = retrogoReq.request.url;
        if (retrogoUrl == null) return false;

        // Telegram / Wallet из window.open — сразу во внешний браузер
        if (await retrogoHandleForcedExternal(retrogoUrl)) {
          return false;
        }

        if (_isGoogleUrl(retrogoUrl)) {
          await _addRandomToUserAgentForGoogle();
        } else {
          await _restoreUserAgentAfterGoogleIfNeeded();
          await _applyNormalUserAgentIfNeeded();
        }

        if (RetrogoKit.retrogoLooksLikeBareMail(retrogoUrl)) {
          final Uri retrogoMail = RetrogoKit.retrogoToMailto(retrogoUrl);
          await RetrogoLinker.retrogoOpen(
            RetrogoKit.retrogoGmailize(retrogoMail),
          );
          return false;
        }

        final String retrogoScheme = retrogoUrl.scheme.toLowerCase();

        if (retrogoScheme == 'mailto') {
          await RetrogoLinker.retrogoOpen(
            RetrogoKit.retrogoGmailize(retrogoUrl),
          );
          return false;
        }

        if (retrogoIsBankScheme(retrogoUrl) ||
            ((retrogoScheme == 'http' || retrogoScheme == 'https') &&
                retrogoIsBankDomain(retrogoUrl))) {
          await retrogoOpenBank(retrogoUrl);
          return false;
        }

        if (retrogoScheme == 'tel') {
          await launchUrl(
            retrogoUrl,
            mode: LaunchMode.externalApplication,
          );
          return false;
        }

        final String retrogoHost = retrogoUrl.host.toLowerCase();
        final bool retrogoIsSocial = retrogoHost.endsWith('facebook.com') ||
            retrogoHost.endsWith('instagram.com') ||
            retrogoHost.endsWith('twitter.com') ||
            retrogoHost.endsWith('x.com');

        if (retrogoIsSocial) {
          await RetrogoLinker.retrogoOpen(retrogoUrl);
          return false;
        }

        if (retrogoIsExternalDestination(retrogoUrl)) {
          final Uri retrogoMapped = retrogoMapExternalToHttp(retrogoUrl);
          await RetrogoLinker.retrogoOpen(retrogoMapped);
          return false;
        }

        // popup-логика: всё, что осталось http/https — открываем во всплывающем WebView
        if (retrogoScheme == 'http' || retrogoScheme == 'https') {
          _openPopup(retrogoReq, urlString: retrogoUrl.toString());
          return true; // говорим WebView, что создаём окно сами
        }

        return false;
      },
    );

    final Widget body = Stack(
      children: <Widget>[
        webView,
        if (retrogoOverlayBusy)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.black87,
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        _buildPopupOverlay(),
      ],
    );

    final Widget wrapped = _safeAreaEnabled ? SafeArea(child: body) : body;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: bgColor,
        body: wrapped,
      ),
    );
  }

  // ========================================================================
  // Внешние “столы” (протоколы/мессенджеры/соцсети)
  // ========================================================================

  bool retrogoIsExternalDestination(Uri retrogoUri) {
    final String retrogoScheme = retrogoUri.scheme.toLowerCase();
    if (retrogoExternalSchemes.contains(retrogoScheme)) {
      return true;
    }

    if (retrogoScheme == 'http' || retrogoScheme == 'https') {
      final String retrogoHost = retrogoUri.host.toLowerCase();
      if (retrogoExternalHosts.contains(retrogoHost)) {
        return true;
      }
      if (retrogoHost.endsWith('t.me')) return true;
      if (retrogoHost.endsWith('wa.me')) return true;
      if (retrogoHost.endsWith('m.me')) return true;
      if (retrogoHost.endsWith('signal.me')) return true;
      if (retrogoHost.endsWith('facebook.com')) return true;
      if (retrogoHost.endsWith('instagram.com')) return true;
      if (retrogoHost.endsWith('twitter.com')) return true;
      if (retrogoHost.endsWith('x.com')) return true;
    }

    return false;
  }

  Uri retrogoMapExternalToHttp(Uri retrogoUri) {
    final String retrogoScheme = retrogoUri.scheme.toLowerCase();

    if (retrogoScheme == 'tg' || retrogoScheme == 'telegram') {
      final Map<String, String> retrogoQp = retrogoUri.queryParameters;
      final String? retrogoDomain = retrogoQp['domain'];
      if (retrogoDomain != null && retrogoDomain.isNotEmpty) {
        return Uri.https('t.me', '/$retrogoDomain', <String, String>{
          if (retrogoQp['start'] != null) 'start': retrogoQp['start']!,
        });
      }
      final String retrogoPath =
      retrogoUri.path.isNotEmpty ? retrogoUri.path : '';
      return Uri.https(
        't.me',
        '/$retrogoPath',
        retrogoUri.queryParameters.isEmpty ? null : retrogoUri.queryParameters,
      );
    }

    if (retrogoScheme == 'whatsapp') {
      final Map<String, String> retrogoQp = retrogoUri.queryParameters;
      final String? retrogoPhone = retrogoQp['phone'];
      final String? retrogoText = retrogoQp['text'];
      if (retrogoPhone != null && retrogoPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${RetrogoKit.retrogoDigitsOnly(retrogoPhone)}',
          <String, String>{
            if (retrogoText != null && retrogoText.isNotEmpty)
              'text': retrogoText,
          },
        );
      }
      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (retrogoText != null && retrogoText.isNotEmpty)
            'text': retrogoText,
        },
      );
    }

    if (retrogoScheme == 'bnl') {
      final String retrogoNewPath =
      retrogoUri.path.isNotEmpty ? retrogoUri.path : '';
      return Uri.https(
        'bnl.com',
        '/$retrogoNewPath',
        retrogoUri.queryParameters.isEmpty ? null : retrogoUri.queryParameters,
      );
    }

    return retrogoUri;
  }

  Future<void> retrogoSendLoadedOnce() async {
    if (retrogoLoadedOnceSent) {
      debugPrint('Wheel Loaded already sent, skip');
      return;
    }

    final int retrogoNow = DateTime.now().millisecondsSinceEpoch;

    await retrogoPostStat(
      retrogoEvent: 'Loaded',
      retrogoTimeStart: retrogoStartLoadTimestamp,
      retrogoTimeFinish: retrogoNow,
      retrogoUrl: retrogoCurrentUrl,
      retrogoAppSid: retrogoSpyInstance.retrogoAppsFlyerUid,
      retrogoFirstPageTs: retrogoFirstPageTimestamp,
    );

    retrogoLoadedOnceSent = true;
  }
}