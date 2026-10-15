import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Platform, HttpHeaders, HttpClient, HttpClientRequest, HttpClientResponse;

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as appsflyer_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'

    show
    MethodChannel,
    SystemChrome,
    SystemUiOverlayStyle,
    MethodCall,
    VoidCallback;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:rollgo/push.dart';
import 'package:rollgo/ret_loader.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

import 'gameap.dart';
import 'external_links.dart';

// ============================================================================
// Константы
// ============================================================================

const String retrogoLoadedOnceKey = 'loaded_once';
const String retrogoStatEndpoint = 'https://myapp.retrogo.team/stat';
const String retrogoCachedFcmKey = 'cached_fcm';
const String retrogoCachedDeepKey = 'cached_deep_push_uri';

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
// Лёгкие сервисы
// ============================================================================

class RetrogoLoggerService {
  static final RetrogoLoggerService sharedInstance =
  RetrogoLoggerService._internalConstructor();

  RetrogoLoggerService._internalConstructor();

  factory RetrogoLoggerService() => sharedInstance;

  final Connectivity retrogoConnectivity = Connectivity();

  void retrogoLogInfo(Object message) => print('[I] $message');
  void retrogoLogWarn(Object message) => print('[W] $message');
  void retrogoLogError(Object message) => print('[E] $message');
}

class RetrogoNetworkService {
  final RetrogoLoggerService retrogoLogger = RetrogoLoggerService();

  Future<void> retrogoPostJson(
      String url,
      Map<String, dynamic> data,
      ) async {
    try {
      await http.post(
        Uri.parse(url),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );
    } catch (error) {
      retrogoLogger.retrogoLogError('postJson error: $error');
    }
  }
}

// ============================================================================
// Утилита: одновременное сохранение JSON в localStorage и SharedPreferences
// ============================================================================

Future<void> retrogoSaveJsonToLocalStorageAndPrefs({
  required InAppWebViewController? controller,
  required String key,
  required Map<String, dynamic> data,
}) async {
  final String jsonString = jsonEncode(data);

  if (controller != null) {
    try {
      await controller.evaluateJavascript(
        source: "localStorage.setItem('$key', JSON.stringify($jsonString));",
      );
    } catch (e, st) {
      RetrogoLoggerService().retrogoLogError(
          'retrogoSaveJsonToLocalStorageAndPrefs localStorage error: $e\n$st');
    }
  }

  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonString);
  } catch (e, st) {
    RetrogoLoggerService().retrogoLogError(
        'retrogoSaveJsonToLocalStorageAndPrefs prefs error: $e\n$st');
  }
}

// ============================================================================
// Профиль устройства
// ============================================================================

class RetrogoDeviceProfile {
  String? retrogoDeviceId;
  String? retrogoSessionId = '';
  String? retrogoPlatformName;
  String? retrogoOsVersion;
  String? retrogoAppVersion;
  String? retrogoLanguageCode;
  String? retrogoTimezoneName;
  bool retrogoPushEnabled = false;

  bool retrogoSafeAreaEnabled = false;
  String? retrogoSafeAreaColor;

  // по умолчанию false, чтобы хуки не ставились,
  // пока сервер явно не пришлёт fpscashier=true
  bool safecasher = false;

  String? retrogoBaseUserAgent;

  Map<String, dynamic>? retrogoLastPushData;

  Map<String, dynamic>? retrogoSavels;

  Future<void> retrogoInitialize() async {
    final DeviceInfoPlugin retrogoDeviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo retrogoAndroidInfo =
      await retrogoDeviceInfoPlugin.androidInfo;
      retrogoDeviceId = retrogoAndroidInfo.id;
      retrogoPlatformName = 'android';
      retrogoOsVersion = retrogoAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo retrogoIosInfo =
      await retrogoDeviceInfoPlugin.iosInfo;
      retrogoDeviceId = retrogoIosInfo.identifierForVendor;
      retrogoPlatformName = 'ios';
      retrogoOsVersion = retrogoIosInfo.systemVersion;
    }

    final PackageInfo retrogoPackageInfo = await PackageInfo.fromPlatform();
    retrogoAppVersion = retrogoPackageInfo.version;
    retrogoLanguageCode = Platform.localeName.split('_').first;
    retrogoTimezoneName = tz_zone.local.name;
    retrogoSessionId = 'test-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> retrogoToMap({String? fcmToken}) => <String, dynamic>{
    'fcm_token': fcmToken ?? 'missing_token',
    'device_id': retrogoDeviceId ?? 'missing_id',
    'app_name': 'retrogo',
    'instance_id': retrogoSessionId ?? 'missing_session',
    'platform': retrogoPlatformName ?? 'missing_system',
    'os_version': retrogoOsVersion ?? 'missing_build',
    'app_version': '1.4.1' ?? 'missing_app',
    'language': retrogoLanguageCode ?? 'en',
    'timezone': retrogoTimezoneName ?? 'UTC',
    'push_enabled': retrogoPushEnabled,
    'safe_area_native': retrogoSafeAreaEnabled,
    'useragent': retrogoBaseUserAgent ?? 'unknown_useragent',
    'savels': retrogoSavels ?? <String, dynamic>{},
    'fpscashier': safecasher,
  };
}

// ============================================================================
// AppsFlyer Spy
// ============================================================================

class RetrogoAnalyticsSpyService {
  appsflyer_core.AppsFlyerOptions? retrogoAppsFlyerOptions;
  appsflyer_core.AppsflyerSdk? retrogoAppsFlyerSdk;

  String retrogoAppsFlyerUid = '';
  String retrogoAppsFlyerData = '';

  Map<String, dynamic>? retrogoAppsFlyerOneLinkData;

  void retrogoStartTracking({VoidCallback? onUpdate}) {
    final appsflyer_core.AppsFlyerOptions retrogoConfig =
    appsflyer_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6776697390',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    retrogoAppsFlyerOptions = retrogoConfig;
    retrogoAppsFlyerSdk = appsflyer_core.AppsflyerSdk(retrogoConfig);

    retrogoAppsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    retrogoAppsFlyerSdk?.startSDK(
      onSuccess: () =>
          RetrogoLoggerService().retrogoLogInfo('RetroCarAnalyticsSpy started'),
      onError: (int code, String msg) => RetrogoLoggerService()
          .retrogoLogError('RetroCarAnalyticsSpy error $code: $msg'),
    );

    retrogoAppsFlyerSdk?.onInstallConversionData((dynamic value) {
      retrogoAppsFlyerData = value.toString();
      onUpdate?.call();
    });

    retrogoAppsFlyerSdk?.getAppsFlyerUID().then((dynamic value) {
      retrogoAppsFlyerUid = value.toString();
      onUpdate?.call();
    });
  }

  void retrogoSetOneLinkData(Map<String, dynamic> data) {
    retrogoAppsFlyerOneLinkData = data;
    RetrogoLoggerService()
        .retrogoLogInfo('RetrogoAnalyticsSpyService: OneLink data updated: $data');
  }
}

// ============================================================================
// FCM фон
// ============================================================================

@pragma('vm:entry-point')
Future<void> retrogoFcmBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  RetrogoLoggerService().retrogoLogInfo('bg-fcm: ${message.messageId}');
  RetrogoLoggerService().retrogoLogInfo('bg-data: ${message.data}');

  final dynamic retrogoLink = message.data['uri'];
  if (retrogoLink != null) {
    try {
      final SharedPreferences retrogoPrefs =
      await SharedPreferences.getInstance();
      await retrogoPrefs.setString(
        retrogoCachedDeepKey,
        retrogoLink.toString(),
      );
    } catch (e) {
      RetrogoLoggerService().retrogoLogError('bg-fcm save deep failed: $e');
    }
  }
}

// ============================================================================
// FCM Bridge — токен
// ============================================================================

class RetrogoFcmBridge {
  final RetrogoLoggerService retrogoLogger = RetrogoLoggerService();

  static const MethodChannel _tokenChannel =
  MethodChannel('com.example.fcm/token');

  String? retrogoToken;
  final List<void Function(String)> retrogoTokenWaiters =
  <void Function(String)>[];

  String? get retrogoFcmToken => retrogoToken;

  Timer? _requestTimer;
  int _requestAttempts = 0;
  final int _maxAttempts = 10;

  RetrogoFcmBridge() {
    _tokenChannel.setMethodCallHandler((MethodCall retrogoCall) async {
      if (retrogoCall.method == 'setToken') {
        final String retrogoTokenString = retrogoCall.arguments as String;
        retrogoLogger.retrogoLogInfo(
            'RetrogoFcmBridge: got token from native channel = $retrogoTokenString');
        if (retrogoTokenString.isNotEmpty) {
          retrogoSetToken(retrogoTokenString);
        }
      }
    });

    retrogoRestoreToken();
    _requestNativeToken();
    _startRequestTimer();
  }

  Future<void> _requestNativeToken() async {
    try {
      retrogoLogger.retrogoLogInfo('RetrogoFcmBridge: request native getToken()');
      final String? token =
      await _tokenChannel.invokeMethod<String>('getToken');
      if (token != null && token.isNotEmpty) {
        retrogoLogger
            .retrogoLogInfo('RetrogoFcmBridge: native getToken() returns $token');
        retrogoSetToken(token);
      } else {
        retrogoLogger
            .retrogoLogWarn('RetrogoFcmBridge: native getToken() returned empty');
      }
    } catch (e) {
      retrogoLogger
          .retrogoLogWarn('RetrogoFcmBridge: getToken invoke error: $e');
    }
  }

  void _startRequestTimer() {
    _requestTimer?.cancel();
    _requestAttempts = 0;

    _requestTimer = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
      if ((retrogoToken ?? '').isNotEmpty) {
        retrogoLogger.retrogoLogInfo(
            'RetrogoFcmBridge: token already set, stop request timer');
        t.cancel();
        return;
      }

      if (_requestAttempts >= _maxAttempts) {
        retrogoLogger.retrogoLogWarn(
            'RetrogoFcmBridge: max getToken attempts reached, stop timer');
        t.cancel();
        return;
      }

      _requestAttempts++;
      retrogoLogger.retrogoLogInfo(
          'RetrogoFcmBridge: retry getToken() attempt #$_requestAttempts');
      await _requestNativeToken();
    });
  }

  Future<void> retrogoRestoreToken() async {
    try {
      final SharedPreferences retrogoPrefs =
      await SharedPreferences.getInstance();
      final String? retrogoCachedToken =
      retrogoPrefs.getString(retrogoCachedFcmKey);
      if (retrogoCachedToken != null && retrogoCachedToken.isNotEmpty) {
        retrogoLogger.retrogoLogInfo(
            'RetrogoFcmBridge: restored cached token = $retrogoCachedToken');
        retrogoSetToken(retrogoCachedToken, notify: false);
      }
    } catch (e) {
      retrogoLogger.retrogoLogError('retrogoRestoreToken error: $e');
    }
  }

  Future<void> retrogoPersistToken(String newToken) async {
    try {
      final SharedPreferences retrogoPrefs =
      await SharedPreferences.getInstance();
      await retrogoPrefs.setString(retrogoCachedFcmKey, newToken);
    } catch (e) {
      retrogoLogger.retrogoLogError('retrogoPersistToken error: $e');
    }
  }

  void retrogoSetToken(
      String newToken, {
        bool notify = true,
      }) {
    retrogoToken = newToken;
    retrogoPersistToken(newToken);

    if (notify) {
      for (final void Function(String) retrogoCallback
      in List<void Function(String)>.from(retrogoTokenWaiters)) {
        try {
          retrogoCallback(newToken);
        } catch (error) {
          retrogoLogger.retrogoLogWarn('fcm waiter error: $error');
        }
      }
      retrogoTokenWaiters.clear();
    }
  }

  Future<void> retrogoWaitForToken(
      Function(String token) retrogoOnToken,
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

      retrogoTokenWaiters.add(retrogoOnToken);
    } catch (error) {
      retrogoLogger.retrogoLogError('retrogoWaitForToken error: $error');
    }
  }

  void dispose() {
    _requestTimer?.cancel();
  }
}

// ============================================================================
// Splash / Hall
// ============================================================================

class RetrogoHall extends StatefulWidget {
  const RetrogoHall({Key? key}) : super(key: key);

  @override
  State<RetrogoHall> createState() => _RetrogoHallState();
}

class _RetrogoHallState extends State<RetrogoHall> {
  final RetrogoFcmBridge retrogoFcmBridgeInstance = RetrogoFcmBridge();
  bool retrogoNavigatedOnce = false;
  Timer? retrogoFallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    retrogoFcmBridgeInstance.retrogoWaitForToken((String retrogoToken) {
      retrogoGoToHarbor(retrogoToken);
    });

    retrogoFallbackTimer = Timer(
      const Duration(seconds: 8),
          () => retrogoGoToHarbor(''),
    );
  }

  void retrogoGoToHarbor(String retrogoSignal) {
    if (retrogoNavigatedOnce) return;
    retrogoNavigatedOnce = true;
    retrogoFallbackTimer?.cancel();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute<Widget>(
        builder: (BuildContext context) =>
            RetrogoHarbor(retrogoSignal: retrogoSignal),
      ),
    );
  }

  @override
  void dispose() {
    retrogoFallbackTimer?.cancel();
    retrogoFcmBridgeInstance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: RetroLoaderScreen(),
        ),
      ),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================

class RetrogoBosunViewModel {
  final RetrogoDeviceProfile retrogoDeviceProfileInstance;
  final RetrogoAnalyticsSpyService retrogoAnalyticsSpyInstance;

  RetrogoBosunViewModel({
    required this.retrogoDeviceProfileInstance,
    required this.retrogoAnalyticsSpyInstance,
  });

  Map<String, dynamic> retrogoDeviceMap(String? fcmToken) =>
      retrogoDeviceProfileInstance.retrogoToMap(fcmToken: fcmToken);

  Map<String, dynamic> retrogoAppsFlyerPayload(
      String? token, {
        String? deepLink,
      }) {
    final Map<String, dynamic> onelinkData =
        retrogoAnalyticsSpyInstance.retrogoAppsFlyerOneLinkData ??
            <String, dynamic>{};

    return <String, dynamic>{
      'content': <String, dynamic>{
        'af_data': retrogoAnalyticsSpyInstance.retrogoAppsFlyerData,
        'af_id': retrogoAnalyticsSpyInstance.retrogoAppsFlyerUid,
        'fb_app_name': 'retrogo',
        'app_name': 'retrogo',
        'onelink': onelinkData,
        'bundle_identifier': 'com.rollgol.goroll.gorolll.rollgo',
        'app_version': '1.4.1',
        'apple_id': '6776697390',
        'fcm_token': token ?? 'no_token',
        'device_id': retrogoDeviceProfileInstance.retrogoDeviceId ?? 'no_device',
        'instance_id':
        retrogoDeviceProfileInstance.retrogoSessionId ?? 'no_instance',
        'platform':
        retrogoDeviceProfileInstance.retrogoPlatformName ?? 'no_type',
        'os_version': retrogoDeviceProfileInstance.retrogoOsVersion ?? 'no_os',
        'language': retrogoDeviceProfileInstance.retrogoLanguageCode ?? 'en',
        'timezone': retrogoDeviceProfileInstance.retrogoTimezoneName ?? 'UTC',
        'push_enabled': retrogoDeviceProfileInstance.retrogoPushEnabled,
        'useruid': retrogoAnalyticsSpyInstance.retrogoAppsFlyerUid,
        'safearea': retrogoDeviceProfileInstance.retrogoSafeAreaEnabled,
        'safearea_color':
        retrogoDeviceProfileInstance.retrogoSafeAreaColor ?? '',
        'useragent':
        retrogoDeviceProfileInstance.retrogoBaseUserAgent ?? 'unknown_useragent',
        'push': retrogoDeviceProfileInstance.retrogoLastPushData ??
            <String, dynamic>{},
        'deep': deepLink,
        'fpscashier': retrogoDeviceProfileInstance.safecasher,
      },
    };
  }
}

class RetrogoCourierService {
  final RetrogoBosunViewModel retrogoBosun;
  final InAppWebViewController? Function() retrogoGetWebViewController;

  RetrogoCourierService({
    required this.retrogoBosun,
    required this.retrogoGetWebViewController,
  });

  Future<InAppWebViewController?> _waitForController({
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    final RetrogoLoggerService logger = RetrogoLoggerService();
    final DateTime start = DateTime.now();

    while (DateTime.now().difference(start) < timeout) {
      final InAppWebViewController? c = retrogoGetWebViewController();
      if (c != null) {
        return c;
      }
      await Future<void>.delayed(interval);
    }

    logger.retrogoLogWarn('_waitForController: timeout, controller is still null');
    return null;
  }

  Future<void> retrogoPutDeviceToLocalStorage(String? token) async {
    final InAppWebViewController? retrogoController = await _waitForController();
    if (retrogoController == null) return;

    final Map<String, dynamic> retrogoMap = retrogoBosun.retrogoDeviceMap(token);
    RetrogoLoggerService()
        .retrogoLogInfo("applocal (${jsonEncode(retrogoMap)});");

    await retrogoSaveJsonToLocalStorageAndPrefs(
      controller: retrogoController,
      key: 'app_data',
      data: retrogoMap,
    );
  }

  Future<void> retrogoSendRawToPage(
      String? token, {
        String? deepLink,
      }) async {
    final InAppWebViewController? retrogoController = await _waitForController();
    if (retrogoController == null) return;

    final Map<String, dynamic> retrogoPayload =
    retrogoBosun.retrogoAppsFlyerPayload(token, deepLink: deepLink);

    final String retrogoJsonString = jsonEncode(retrogoPayload);

    RetrogoLoggerService().retrogoLogInfo('SendRawData: $retrogoJsonString');

    final String jsSafeJson = jsonEncode(retrogoJsonString);
    final String jsCode = 'sendRawData($jsSafeJson);';

    try {
      await retrogoController.evaluateJavascript(source: jsCode);
    } catch (e, st) {
      RetrogoLoggerService()
          .retrogoLogError('retrogoSendRawToPage evaluateJavascript error: $e\n$st');
    }
  }
}

// ============================================================================
// Статистика
// ============================================================================

Future<String> retrogoResolveFinalUrl(
    String startUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient retrogoHttpClient = HttpClient();

  try {
    Uri retrogoCurrentUri = Uri.parse(startUrl);

    for (int retrogoIndex = 0; retrogoIndex < maxHops; retrogoIndex++) {
      final HttpClientRequest retrogoRequest =
      await retrogoHttpClient.getUrl(retrogoCurrentUri);
      retrogoRequest.followRedirects = false;
      final HttpClientResponse retrogoResponse = await retrogoRequest.close();

      if (retrogoResponse.isRedirect) {
        final String? retrogoLocationHeader =
        retrogoResponse.headers.value(HttpHeaders.locationHeader);
        if (retrogoLocationHeader == null || retrogoLocationHeader.isEmpty) {
          break;
        }

        final Uri retrogoNextUri = Uri.parse(retrogoLocationHeader);
        retrogoCurrentUri = retrogoNextUri.hasScheme
            ? retrogoNextUri
            : retrogoCurrentUri.resolveUri(retrogoNextUri);
        continue;
      }

      return retrogoCurrentUri.toString();
    }

    return retrogoCurrentUri.toString();
  } catch (error) {
    print('goldenLuxuryResolveFinalUrl error: $error');
    return startUrl;
  } finally {
    retrogoHttpClient.close(force: true);
  }
}

Future<void> retrogoPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final String retrogoResolvedUrl = await retrogoResolveFinalUrl(url);

    final Map<String, dynamic> retrogoPayload = <String, dynamic>{
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': retrogoResolvedUrl,
      'appleID': '6776697390',
      'open_count': '$appSid/$timeStart',
    };

    print('goldenLuxuryStat $retrogoPayload');

    final http.Response retrogoResponse = await http.post(
      Uri.parse('$retrogoStatEndpoint/$appSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(retrogoPayload),
    );

    print(
        'goldenLuxuryStat resp=${retrogoResponse.statusCode} body=${retrogoResponse.body}');
  } catch (error) {
    print('goldenLuxuryPostStat error: $error');
  }
}

// ============================================================================
// Банковские утилиты
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
    print('retrogoOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// Главный WebView — Harbor
// ============================================================================

class RetrogoHarbor extends StatefulWidget {
  final String? retrogoSignal;

  const RetrogoHarbor({super.key, required this.retrogoSignal});

  @override
  State<RetrogoHarbor> createState() => _RetrogoHarborState();
}

class _RetrogoHarborState extends State<RetrogoHarbor>
    with WidgetsBindingObserver {
  InAppWebViewController? retrogoWebViewController;

  InAppWebViewController? retrogoPopupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;

  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  bool _isOpeningExternalNewTab = false;
  final Set<String> _handledNewTabUrls = <String>{};

  Timer? _parentInstallTimer;
  Timer? _popupInstallTimer;

  final String retrogoHomeUrl = 'https://myapp.retrogo.team/';

  int retrogoWebViewKeyCounter = 0;
  DateTime? retrogoSleepAt;
  bool retrogoVeilVisible = false;
  double retrogoWarmProgress = 0.0;
  late Timer retrogoWarmTimer;
  final int retrogoWarmSeconds = 6;
  bool retrogoCoverVisible = true;

  bool retrogoLoadedOnceSent = false;
  int? retrogoFirstPageTimestamp;

  RetrogoCourierService? retrogoCourier;
  RetrogoBosunViewModel? retrogoBosunInstance;

  String retrogoCurrentUrl = '';
  int retrogoStartLoadTimestamp = 0;

  final RetrogoDeviceProfile retrogoDeviceProfileInstance =
  RetrogoDeviceProfile();
  final RetrogoAnalyticsSpyService retrogoAnalyticsSpyInstance =
  RetrogoAnalyticsSpyService();

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

  final Set<String> retrogoExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
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

  String? retrogoDeepLinkFromPush;

  String? _baseUserAgent;
  String _currentUserAgent = "";
  String? _currentUrl;

  String? _serverUserAgent;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = const Color(0xFF000000);

  bool _startupSendRawDone = false;

  String? _pendingLoadedJs;

  bool _loadedJsExecutedOnce = false;

  bool _isInGoogleAuth = false;

  List<String> _buttonWhitelist = <String>[];
  bool _showBackButton = false;

  bool _backButtonHiddenAfterTap = false;

  bool _isCurrentlyOnGoogle = false;

  static const MethodChannel _appsFlyerDeepLinkChannel =
  MethodChannel('appsflyer_deeplink_channel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    retrogoFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;
    _currentUrl = retrogoHomeUrl;

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          retrogoCoverVisible = false;
        });
      }
    });

    Future<void>.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() {
        retrogoVeilVisible = true;
      });
    });

    _bindPushChannelFromAppDelegate();
    _bindAppsFlyerDeepLinkChannel();
    retrogoBootHarbor();
  }

  bool _isAboutBlankUrl(String? value) {
    final String u = (value ?? '').trim().toLowerCase();
    return u.isEmpty || u == 'about:blank' || u.startsWith('about:blank');
  }

  bool _isAboutBlankUri(Uri? uri) => _isAboutBlankUrl(uri?.toString());

  void _bindAppsFlyerDeepLinkChannel() {
    _appsFlyerDeepLinkChannel.setMethodCallHandler(
          (MethodCall call) async {
        if (call.method == 'onDeepLink') {
          try {
            final dynamic args = call.arguments;

            Map<String, dynamic> payload;

            print(" Data Deepl link ${args.toString()}");
            if (args is Map) {
              payload = Map<String, dynamic>.from(args as Map);
            } else if (args is String) {
              payload = jsonDecode(args) as Map<String, dynamic>;
            } else {
              payload = <String, dynamic>{'raw': args.toString()};
            }

            RetrogoLoggerService().retrogoLogInfo(
              'AppsFlyer onDeepLink from iOS: $payload',
            );

            final dynamic raw = payload['raw'];
            if (raw is Map) {
              final Map<String, dynamic> normalized =
              Map<String, dynamic>.from(raw as Map);

              print("One Link Data $normalized");
              retrogoAnalyticsSpyInstance.retrogoSetOneLinkData(normalized);
            } else {
              retrogoAnalyticsSpyInstance.retrogoSetOneLinkData(payload);
            }
          } catch (e, st) {
            RetrogoLoggerService()
                .retrogoLogError('Error in onDeepLink handler: $e\n$st');
          }
        }
      },
    );
  }

  void _bindPushChannelFromAppDelegate() {
    const MethodChannel pushChannel = MethodChannel('com.example.fcm/push');

    pushChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'setPushData') {
        try {
          Map<String, dynamic> pushData;
          if (call.arguments is Map) {
            pushData = Map<String, dynamic>.from(call.arguments);
            print("Get Push Data $pushData");
          } else if (call.arguments is String) {
            pushData =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
          } else {
            pushData = <String, dynamic>{'raw': call.arguments.toString()};
          }

          RetrogoLoggerService()
              .retrogoLogInfo('Got push data from AppDelegate: $pushData');

          retrogoDeviceProfileInstance.retrogoLastPushData = pushData;

          final dynamic uriRaw = pushData['uri'] ?? pushData['deep_link'];
          if (uriRaw != null && uriRaw.toString().isNotEmpty) {
            final String u = uriRaw.toString();
            retrogoDeepLinkFromPush = u;
            await retrogoSaveCachedDeep(u);
          }
        } catch (e, st) {
          RetrogoLoggerService()
              .retrogoLogError('setPushData handler error: $e\n$st');
        }
      }
    });
  }

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google.com') ||
        full.contains('accounts.google.') ||
        full.contains('googleusercontent.com') ||
        full.contains('gstatic.com');
  }

  Future<void> _applyGoogleUserAgent() async {
    if (retrogoWebViewController == null) return;

    const String googleUa = 'random';

    if (_currentUserAgent == googleUa) {
      RetrogoLoggerService()
          .retrogoLogInfo('[UA] Already set to "random" for Google, skip');
      return;
    }

    RetrogoLoggerService()
        .retrogoLogInfo('[UA] Applying GOOGLE User-Agent: $googleUa');

    try {
      await retrogoWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      _currentUserAgent = googleUa;
      _isCurrentlyOnGoogle = true;
      print('[UA] GOOGLE WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      RetrogoLoggerService()
          .retrogoLogError('Error setting Google User-Agent: $e');
    }
  }

  Future<void> _applyGoogleUserAgentForPopup() async {
    if (retrogoPopupWebViewController == null) return;

    const String googleUa = 'random';

    RetrogoLoggerService()
        .retrogoLogInfo('[UA] Applying GOOGLE User-Agent to POPUP: $googleUa');

    try {
      await retrogoPopupWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      print('[UA] GOOGLE POPUP USER AGENT: $googleUa');
    } catch (e) {
      RetrogoLoggerService()
          .retrogoLogError('Error setting Google User-Agent for popup: $e');
    }
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

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (retrogoWebViewController == null) return;

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await retrogoWebViewController!.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          retrogoDeviceProfileInstance.retrogoBaseUserAgent = _baseUserAgent;
          RetrogoLoggerService()
              .retrogoLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        RetrogoLoggerService()
            .retrogoLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      RetrogoLoggerService()
          .retrogoLogWarn('Base User-Agent is still null/empty, skip UA update');
      return;
    }

    RetrogoLoggerService().retrogoLogInfo(
        'Server UA payload: fullua="$fullua", uatail="$uatail", base="$_baseUserAgent"');

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = "${_baseUserAgent!}";
    }

    _serverUserAgent = newUa;
    RetrogoLoggerService()
        .retrogoLogInfo('Server UA calculated and stored: $_serverUserAgent');
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (retrogoWebViewController == null) return;

    if (_isCurrentlyOnGoogle) {
      RetrogoLoggerService().retrogoLogInfo(
          '[UA] Currently on Google page, keeping "random" UA');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) {
      RetrogoLoggerService()
          .retrogoLogInfo('Normal UA unchanged, keeping: $_currentUserAgent');
      return;
    }

    RetrogoLoggerService()
        .retrogoLogInfo('Applying NORMAL WebView User-Agent: $targetUa');

    try {
      await retrogoWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      print('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      RetrogoLoggerService().retrogoLogError(
          'Error while setting normal User-Agent "$targetUa": $e');
    }
  }

  Future<void> _switchUserAgentForUrl(Uri? uri) async {
    if (uri == null) return;

    if (_isGoogleUrl(uri)) {
      _isCurrentlyOnGoogle = true;
      await _applyGoogleUserAgent();
    } else {
      if (_isCurrentlyOnGoogle) {
        _isCurrentlyOnGoogle = false;
      }
      await _applyNormalUserAgentIfNeeded();
    }
  }

  Future<void> printJsUserAgent() async {
    if (retrogoWebViewController == null) return;

    try {
      final ua = await retrogoWebViewController!.evaluateJavascript(
        source: "navigator.userAgent",
      );

      if (ua is String) {
        print('[JS UA] navigator.userAgent = $ua');
      } else {
        print('[JS UA] navigator.userAgent (non-string) = $ua');
      }
    } catch (e, st) {
      print('Error reading navigator.userAgent: $e\n$st');
    }
  }

  Future<void> debugPrintCurrentUserAgent() async {
    RetrogoLoggerService()
        .retrogoLogInfo('[STATE UA] _currentUserAgent = $_currentUserAgent');
    await printJsUserAgent();
  }

  Future<void> retrogoLoadLoadedFlag() async {
    final SharedPreferences retrogoPrefs = await SharedPreferences.getInstance();
    retrogoLoadedOnceSent = retrogoPrefs.getBool(retrogoLoadedOnceKey) ?? false;
  }

  Future<void> retrogoSaveLoadedFlag() async {
    final SharedPreferences retrogoPrefs = await SharedPreferences.getInstance();
    await retrogoPrefs.setBool(retrogoLoadedOnceKey, true);
    retrogoLoadedOnceSent = true;
  }

  Future<void> retrogoLoadCachedDeep() async {
    try {
      final SharedPreferences retrogoPrefs = await SharedPreferences.getInstance();
      final String? retrogoCached = retrogoPrefs.getString(retrogoCachedDeepKey);
      if ((retrogoCached ?? '').isNotEmpty) {
        retrogoDeepLinkFromPush = retrogoCached;
      }
    } catch (_) {}
  }

  Future<void> retrogoSaveCachedDeep(String uri) async {
    try {
      final SharedPreferences retrogoPrefs = await SharedPreferences.getInstance();
      await retrogoPrefs.setString(retrogoCachedDeepKey, uri);
    } catch (_) {}
  }

  Future<void> retrogoSendLoadedOnce({
    required String url,
    required int timestart,
  }) async {
    if (retrogoLoadedOnceSent) return;

    final int retrogoNow = DateTime.now().millisecondsSinceEpoch;

    await retrogoPostStat(
      event: 'Loaded',
      timeStart: timestart,
      timeFinish: retrogoNow,
      url: url,
      appSid: retrogoAnalyticsSpyInstance.retrogoAppsFlyerUid,
      firstPageLoadTs: retrogoFirstPageTimestamp,
    );

    await retrogoSaveLoadedFlag();
  }

  void retrogoBootHarbor() {
    retrogoStartWarmProgress();
    retrogoWireFcmHandlers();
    retrogoAnalyticsSpyInstance.retrogoStartTracking(
      onUpdate: () => setState(() {}),
    );
    retrogoBindNotificationTap();
    retrogoPrepareDeviceProfile();
  }

  void retrogoWireFcmHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage retrogoMessage) async {
      final dynamic retrogoLink = retrogoMessage.data['uri'];
      if (retrogoLink != null) {
        final String retrogoUri = retrogoLink.toString();
        retrogoDeepLinkFromPush = retrogoUri;
        await retrogoSaveCachedDeep(retrogoUri);
      } else {
        retrogoResetHomeAfterDelay();
      }
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage retrogoMessage) async {
      final dynamic retrogoLink = retrogoMessage.data['uri'];
      if (retrogoLink != null) {
        final String retrogoUri = retrogoLink.toString();
        retrogoDeepLinkFromPush = retrogoUri;
        await retrogoSaveCachedDeep(retrogoUri);

        retrogoNavigateToUri(retrogoUri);

        await retrogoPushDeviceInfo();
        await retrogoPushAppsFlyerData();
      } else {
        retrogoResetHomeAfterDelay();
      }
    });
  }

  void retrogoBindNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNotificationTap') {
        final Map<String, dynamic> retrogoPayload =
        Map<String, dynamic>.from(call.arguments);
        final String? retrogoUriRaw = retrogoPayload['uri']?.toString();

        if (retrogoUriRaw != null &&
            retrogoUriRaw.isNotEmpty &&
            !retrogoUriRaw.contains('Нет URI')) {
          final String retrogoUri = retrogoUriRaw;
          retrogoDeepLinkFromPush = retrogoUri;
          await retrogoSaveCachedDeep(retrogoUri);

          if (!context.mounted) return;

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext context) => RetrogoTableView(retrogoUri),
            ),
                (Route<dynamic> route) => false,
          );

          await retrogoPushDeviceInfo();
          await retrogoPushAppsFlyerData();
        }
      }
    });
  }

  Future<void> retrogoPrepareDeviceProfile() async {
    try {
      await retrogoDeviceProfileInstance.retrogoInitialize();

      final FirebaseMessaging retrogoMessaging = FirebaseMessaging.instance;
      final NotificationSettings retrogoSettings =
      await retrogoMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      retrogoDeviceProfileInstance.retrogoPushEnabled =
          retrogoSettings.authorizationStatus ==
              AuthorizationStatus.authorized ||
              retrogoSettings.authorizationStatus ==
                  AuthorizationStatus.provisional;

      await retrogoLoadLoadedFlag();
      await retrogoLoadCachedDeep();

      retrogoBosunInstance = RetrogoBosunViewModel(
        retrogoDeviceProfileInstance: retrogoDeviceProfileInstance,
        retrogoAnalyticsSpyInstance: retrogoAnalyticsSpyInstance,
      );

      retrogoCourier = RetrogoCourierService(
        retrogoBosun: retrogoBosunInstance!,
        retrogoGetWebViewController: () => retrogoWebViewController,
      );
    } catch (error) {
      RetrogoLoggerService().retrogoLogError('prepareDeviceProfile fail: $error');
    }
  }

  void retrogoNavigateToUri(String link) async {
    try {
      await retrogoWebViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(link)),
      );
    } catch (error) {
      RetrogoLoggerService().retrogoLogError('navigate error: $error');
    }
  }

  void retrogoResetHomeAfterDelay() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      try {
        retrogoWebViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(retrogoHomeUrl)),
        );
      } catch (_) {}
    });
  }

  String? _resolveTokenForShip() {
    if (widget.retrogoSignal != null && widget.retrogoSignal!.isNotEmpty) {
      return widget.retrogoSignal;
    }
    return null;
  }

  Future<void> _sendAllDataToPageTwice() async {
    await retrogoPushDeviceInfo();

    Future<void>.delayed(const Duration(seconds: 6), () async {
      await retrogoPushDeviceInfo();
      await retrogoPushAppsFlyerData();
    });
  }

  Future<void> retrogoPushDeviceInfo() async {
    final String? retrogoToken = _resolveTokenForShip();

    try {
      await retrogoCourier?.retrogoPutDeviceToLocalStorage(retrogoToken);
    } catch (error) {
      RetrogoLoggerService().retrogoLogError('pushDeviceInfo error: $error');
    }
  }

  Future<void> retrogoPushAppsFlyerData() async {
    final String? retrogoToken = _resolveTokenForShip();

    try {
      await retrogoCourier?.retrogoSendRawToPage(
        retrogoToken,
        deepLink: retrogoDeepLinkFromPush,
      );
    } catch (error) {
      RetrogoLoggerService().retrogoLogError('pushAppsFlyerData error: $error');
    }
  }

  void retrogoStartWarmProgress() {
    int retrogoTick = 0;
    retrogoWarmProgress = 0.0;

    retrogoWarmTimer =
        Timer.periodic(const Duration(milliseconds: 100), (Timer timer) {
          if (!mounted) return;

          setState(() {
            retrogoTick++;
            retrogoWarmProgress = retrogoTick / (retrogoWarmSeconds * 10);

            if (retrogoWarmProgress >= 1.0) {
              retrogoWarmProgress = 1.0;
              retrogoWarmTimer.cancel();
            }
          });
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      retrogoSleepAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && retrogoSleepAt != null) {
        final DateTime retrogoNow = DateTime.now();
        final Duration retrogoDrift = retrogoNow.difference(retrogoSleepAt!);

        if (retrogoDrift > const Duration(minutes: 25)) {
          retrogoReboardHarbor();
        }
      }
      retrogoSleepAt = null;
    }
  }

  void retrogoReboardHarbor() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
              RetrogoHarbor(retrogoSignal: widget.retrogoSignal),
        ),
            (Route<dynamic> route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    retrogoWarmTimer.cancel();

    _parentInstallTimer?.cancel();
    _popupInstallTimer?.cancel();

    retrogoWebViewController = null;
    retrogoPopupWebViewController = null;

    super.dispose();
  }

  bool retrogoIsBareEmail(Uri uri) {
    final String retrogoScheme = uri.scheme;
    if (retrogoScheme.isNotEmpty) return false;
    final String retrogoRaw = uri.toString();
    return retrogoRaw.contains('@') && !retrogoRaw.contains(' ');
  }

  Uri retrogoToMailto(Uri uri) {
    final String retrogoFull = uri.toString();
    final List<String> retrogoParts = retrogoFull.split('?');
    final String retrogoEmail = retrogoParts.first;
    final Map<String, String> retrogoQueryParams = retrogoParts.length > 1
        ? Uri.splitQueryString(retrogoParts[1])
        : <String, String>{};

    return Uri(
      scheme: 'mailto',
      path: retrogoEmail,
      queryParameters:
      retrogoQueryParams.isEmpty ? null : retrogoQueryParams,
    );
  }

  Future<bool> retrogoOpenMailExternal(Uri mailto) async {
    try {
      final String scheme = mailto.scheme.toLowerCase();
      final String path = mailto.path.toLowerCase();

      RetrogoLoggerService().retrogoLogInfo(
          'retrogoOpenMailExternal: scheme=$scheme path=$path uri=$mailto');

      if (scheme != 'mailto') {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        RetrogoLoggerService()
            .retrogoLogInfo('retrogoOpenMailExternal: non-mailto result=$ok');
        return ok;
      }

      final bool can = await canLaunchUrl(mailto);
      RetrogoLoggerService()
          .retrogoLogInfo('retrogoOpenMailExternal: canLaunchUrl(mailto) = $can');

      if (can) {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        RetrogoLoggerService().retrogoLogInfo(
            'retrogoOpenMailExternal: externalApplication result=$ok');
        if (ok) return true;
      }

      RetrogoLoggerService().retrogoLogWarn(
          'retrogoOpenMailExternal: no native handler for mailto, fallback to Gmail Web');
      final Uri gmailUri = retrogoGmailizeMailto(mailto);
      final bool webOk = await retrogoOpenWeb(gmailUri);
      RetrogoLoggerService().retrogoLogInfo(
          'retrogoOpenMailExternal: Gmail Web fallback result=$webOk');
      return webOk;
    } catch (e, st) {
      RetrogoLoggerService().retrogoLogError(
          'retrogoOpenMailExternal error: $e\n$st; url=$mailto');
      return false;
    }
  }

  Future<bool> retrogoOpenMailWeb(Uri mailto) async {
    final Uri retrogoGmailUri = retrogoGmailizeMailto(mailto);
    return retrogoOpenWeb(retrogoGmailUri);
  }

  Uri retrogoGmailizeMailto(Uri mailUri) {
    final Map<String, String> retrogoQueryParams = mailUri.queryParameters;

    final Map<String, String> retrogoParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (mailUri.path.isNotEmpty) 'to': mailUri.path,
      if ((retrogoQueryParams['subject'] ?? '').isNotEmpty)
        'su': retrogoQueryParams['subject']!,
      if ((retrogoQueryParams['body'] ?? '').isNotEmpty)
        'body': retrogoQueryParams['body']!,
      if ((retrogoQueryParams['cc'] ?? '').isNotEmpty)
        'cc': retrogoQueryParams['cc']!,
      if ((retrogoQueryParams['bcc'] ?? '').isNotEmpty)
        'bcc': retrogoQueryParams['bcc']!,
    };

    return Uri.https('mail.google.com', '/mail/', retrogoParams);
  }

  bool retrogoIsPlatformLink(Uri uri) {
    final String retrogoScheme = uri.scheme.toLowerCase();
    if (retrogoSpecialSchemes.contains(retrogoScheme)) {
      return true;
    }

    if (retrogoScheme == 'http' || retrogoScheme == 'https') {
      final String retrogoHost = uri.host.toLowerCase();

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

  String retrogoDigitsOnly(String source) =>
      source.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri retrogoHttpizePlatformUri(Uri uri) {
    final String retrogoScheme = uri.scheme.toLowerCase();

    if (retrogoScheme == 'tg' || retrogoScheme == 'telegram') {
      final Map<String, String> retrogoQp = uri.queryParameters;
      final String? retrogoDomain = retrogoQp['domain'];

      if (retrogoDomain != null && retrogoDomain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$retrogoDomain',
          <String, String>{
            if (retrogoQp['start'] != null) 'start': retrogoQp['start']!,
          },
        );
      }

      final String retrogoPath = uri.path.isNotEmpty ? uri.path : '';

      return Uri.https(
        't.me',
        '/$retrogoPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if ((retrogoScheme == 'http' || retrogoScheme == 'https') &&
        uri.host.toLowerCase().endsWith('t.me')) {
      return uri;
    }

    if (retrogoScheme == 'viber') {
      return uri;
    }

    if (retrogoScheme == 'whatsapp') {
      final Map<String, String> retrogoQp = uri.queryParameters;
      final String? retrogoPhone = retrogoQp['phone'];
      final String? retrogoText = retrogoQp['text'];

      if (retrogoPhone != null && retrogoPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${retrogoDigitsOnly(retrogoPhone)}',
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

    if ((retrogoScheme == 'http' || retrogoScheme == 'https') &&
        (uri.host.toLowerCase().endsWith('wa.me') ||
            uri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return uri;
    }

    if (retrogoScheme == 'skype') {
      return uri;
    }

    if (retrogoScheme == 'fb-messenger') {
      final String retrogoPath =
      uri.pathSegments.isNotEmpty ? uri.pathSegments.join('/') : '';
      final Map<String, String> retrogoQp = uri.queryParameters;

      final String retrogoId =
          retrogoQp['id'] ?? retrogoQp['user'] ?? retrogoPath;

      if (retrogoId.isNotEmpty) {
        return Uri.https(
          'm.me',
          '/$retrogoId',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return Uri.https(
        'm.me',
        '/',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if (retrogoScheme == 'sgnl') {
      final Map<String, String> retrogoQp = uri.queryParameters;
      final String? retrogoPhone = retrogoQp['phone'];
      final String? retrogoUsername = retrogoQp['username'];

      if (retrogoPhone != null && retrogoPhone.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#p/${retrogoDigitsOnly(retrogoPhone)}',
        );
      }

      if (retrogoUsername != null && retrogoUsername.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#u/$retrogoUsername',
        );
      }

      final String retrogoPath = uri.pathSegments.join('/');
      if (retrogoPath.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/$retrogoPath',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return uri;
    }

    if (retrogoScheme == 'tel') {
      return Uri.parse('tel:${retrogoDigitsOnly(uri.path)}');
    }

    if (retrogoScheme == 'mailto') {
      return uri;
    }

    if (retrogoScheme == 'bnl') {
      final String retrogoNewPath = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https(
        'bnl.com',
        '/$retrogoNewPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    return uri;
  }

  Future<bool> retrogoOpenWeb(Uri uri) async {
    try {
      if (await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }

      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      try {
        return await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }

  Future<bool> retrogoOpenExternal(Uri uri) async {
    try {
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      return false;
    }
  }

  void retrogoHandleServerSavedata(String savedata) {
    print('onServerResponse savedata: $savedata');
    if(savedata=='false'){
      Navigator.pushReplacement(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) => SimpleWebViewPage2(),
        ),
      );
    }
  }

  Color _parseHexColor(String hex) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) {
      value = 'FF$value';
    }
    final intColor = int.tryParse(value, radix: 16) ?? 0xFF000000;
    return Color(intColor);
  }

  Future<void> _updateAppDataInLocalStorageFromProfile() async {
    final InAppWebViewController? controller = retrogoWebViewController;
    if (controller == null) return;

    final String? token = _resolveTokenForShip();
    final Map<String, dynamic> map =
    retrogoDeviceProfileInstance.retrogoToMap(fcmToken: token);

    RetrogoLoggerService()
        .retrogoLogInfo('updateAppDataFromProfile: ${jsonEncode(map)}');

    await retrogoSaveJsonToLocalStorageAndPrefs(
      controller: controller,
      key: 'app_data',
      data: map,
    );
  }

  void _updateExtraDataFromServerPayload(Map<dynamic, dynamic> root) {
    try {
      final dynamic adataRaw = root['adata'];
      if (adataRaw is Map) {
        final Map adata = adataRaw;

        final dynamic buttonswlRaw = adata['buttonswl'];
        if (buttonswlRaw is List) {
          final List<String> list = buttonswlRaw
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          setState(() {
            _buttonWhitelist = list;
          });
          RetrogoLoggerService()
              .retrogoLogInfo('buttonswl updated: $_buttonWhitelist');
          _updateBackButtonVisibility();
        }

        // fpscashier из adata → профиль → localStorage
        if (adata.containsKey('fpscashier')) {
          final dynamic fpsRaw = adata['fpscashier'];
          bool? fpsValue;

          if (fpsRaw is bool) {
            fpsValue = fpsRaw;
          } else if (fpsRaw is num) {
            fpsValue = fpsRaw != 0;
          } else if (fpsRaw is String) {
            final String v = fpsRaw.toLowerCase().trim();
            if (v == 'true' || v == '1' || v == 'yes') fpsValue = true;
            if (v == 'false' || v == '0' || v == 'no') fpsValue = false;
          }

          if (fpsValue != null) {
            final bool old = retrogoDeviceProfileInstance.safecasher;
            retrogoDeviceProfileInstance.safecasher = fpsValue;
            RetrogoLoggerService().retrogoLogInfo(
                'fpscashier updated from server payload: $fpsValue');

            _updateAppDataInLocalStorageFromProfile();

            // при переходе из false -> true
            if (!old && fpsValue && retrogoWebViewController != null) {
              RetrogoLoggerService().retrogoLogInfo(
                  'fpscashier switched to true, installing JS hooks now');
              _scheduleSafeInstall(retrogoWebViewController!, label: 'parent');
            }
          }
        }

        final dynamic savelsRaw = adata['savels'];
        if (savelsRaw is Map) {
          retrogoDeviceProfileInstance.retrogoSavels =
          Map<String, dynamic>.from(savelsRaw);
          RetrogoLoggerService().retrogoLogInfo(
              'savels stored in profile: ${retrogoDeviceProfileInstance.retrogoSavels}');
          _updateAppDataInLocalStorageFromProfile();
        }
      }
    } catch (e, st) {
      RetrogoLoggerService()
          .retrogoLogError('Error in _updateExtraDataFromServerPayload: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    RetrogoLoggerService()
        .retrogoLogInfo('SAFEAREA RAW PAYLOAD: ${jsonEncode(root)}');

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

    RetrogoLoggerService().retrogoLogInfo(
        'SAFEAREA PARSED: enabled=$safearea, light=$bgLightHex, dark=$bgDarkHex');

    if (safearea == null) {
      return;
    }

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    final bool enabled = safearea;
    Color background =
    enabled ? const Color(0xFF1A1A22) : const Color(0xFF000000);

    if (enabled && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex);
    }

    setState(() {
      _safeAreaEnabled = enabled;
      _safeAreaBackgroundColor = background;
      retrogoDeviceProfileInstance.retrogoSafeAreaEnabled = enabled;
      retrogoDeviceProfileInstance.retrogoSafeAreaColor =
      enabled ? (chosenHex ?? '#1A1A22') : '';
    });

    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool('safearea_enabled', enabled);
        await prefs.setString(
          'safearea_color',
          retrogoDeviceProfileInstance.retrogoSafeAreaColor ?? '',
        );
        RetrogoLoggerService().retrogoLogInfo(
          'SafeArea saved to prefs: enabled=$enabled, color="${retrogoDeviceProfileInstance.retrogoSafeAreaColor}"',
        );
      } catch (e, st) {
        RetrogoLoggerService()
            .retrogoLogError('Error saving SafeArea to prefs: $e\n$st');
      }
    }();

    RetrogoLoggerService().retrogoLogInfo(
        'SAFEAREA STATE UPDATED: enabled=$_safeAreaEnabled, color=$_safeAreaBackgroundColor (brightness=$platformBrightness)');
  }

  bool _matchesButtonWhitelist(String url) {
    if (url.isEmpty) return false;
    if (_buttonWhitelist.isEmpty) return false;
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }

    final String host = uri.host.toLowerCase();
    final String full = uri.toString();

    for (final String item in _buttonWhitelist) {
      final String trimmed = item.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        if (full.startsWith(trimmed)) return true;
      } else {
        final String domain = trimmed.toLowerCase();
        if (host == domain || host.endsWith('.$domain')) return true;
      }
    }

    return false;
  }

  Future<void> _updateBackButtonVisibility() async {
    final String current = _currentUrl ?? retrogoCurrentUrl;
    final bool shouldShow = _matchesButtonWhitelist(current);

    if (_backButtonHiddenAfterTap) {
      _backButtonHiddenAfterTap = false;
    }

    if (shouldShow != _showBackButton) {
      if (mounted) {
        setState(() {
          _showBackButton = shouldShow;
        });
      } else {
        _showBackButton = shouldShow;
      }
    }
  }

  Future<void> _handleBackButtonPressed() async {
    if (mounted) {
      setState(() {
        _backButtonHiddenAfterTap = true;
        _showBackButton = false;
      });
    } else {
      _backButtonHiddenAfterTap = true;
      _showBackButton = false;
    }

    if (_isPopupVisible) {
      await _handlePopupBackPressed();
      return;
    }

    if (retrogoWebViewController == null) return;
    try {
      if (await retrogoWebViewController!.canGoBack()) {
        await retrogoWebViewController!.goBack();
      } else {
        await retrogoWebViewController!.loadUrl(
          urlRequest: URLRequest(url: WebUri(retrogoHomeUrl)),
        );
      }
    } catch (e, st) {
      RetrogoLoggerService()
          .retrogoLogError('Error on back button pressed: $e\n$st');
    }
  }

  InAppWebViewSettings _mainWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      useOnNavigationResponse: true,
      supportMultipleWindows: true,
      transparentBackground: true,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  InAppWebViewSettings _popupWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
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

  Future<void> _safeEvaluateJavascript(
      InAppWebViewController? controller, {
        required String source,
        String debugName = 'js',
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      print('WERLOG: safeEvaluateJavascript error [$debugName]: $e');
    }
  }

  Future<void> _installJsErrorLogger(InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installJsErrorLogger',
      source: r'''
        (function() {
          if (window.__ncupJsLoggerInstalled) return;
          window.__ncupJsLoggerInstalled = true;

          function serializeError(err) {
            try {
              if (!err) return null;
              var plain = {};
              Object.getOwnPropertyNames(err).forEach(function(key) {
                plain[key] = err[key];
              });
              return plain;
            } catch (_) {
              return { message: String(err) };
            }
          }

          window.onerror = function(message, source, lineno, colno, error) {
            try {
              var payload = {
                type: 'onerror',
                message: String(message || ''),
                source: String(source || ''),
                lineno: lineno || 0,
                colno: colno || 0,
                error: serializeError(error)
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger onerror inner fail', e);
            }
          };

          window.addEventListener('unhandledrejection', function(event) {
            try {
              var reason = event.reason;
              var payload = {
                type: 'unhandledrejection',
                reason: serializeError(reason) || { message: String(reason || '') }
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger unhandledrejection inner fail', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installPostMessageBridge(
      InAppWebViewController controller, {
        required String label,
      }) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installPostMessageBridge-$label',
      source: '''
        (function() {
          if (window.__ncupPostMessageBridgeInstalled_$label) return;
          window.__ncupPostMessageBridgeInstalled_$label = true;

          window.addEventListener('message', function(event) {
            try {
              var dataRaw = event.data;
              var dataString;
              try {
                dataString = JSON.stringify(dataRaw);
              } catch (e) {
                dataString = String(dataRaw);
              }

              var payload = {
                label: '$label',
                origin: String(event.origin || ''),
                data: dataString,
                href: String(window.location.href || '')
              };

              console.log('[NCUP postMessage $label]', payload);

              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupPostMessage', payload);
              }

              try {
                var parsed = dataRaw;
                if (typeof parsed === 'string') {
                  parsed = JSON.parse(parsed);
                }
                if (parsed && parsed.type === 'newTab' && parsed.url) {
                  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('NcupCheckoutAction', parsed);
                  }
                }
              } catch (_) {}
            } catch (e) {
              console.log('NcupPostMessage bridge error', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installCheckoutInterceptor(
      InAppWebViewController controller,
      ) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installCheckoutInterceptor',
      source: r'''
        (function() {
          if (window.__ncupCheckoutInterceptorInstalled) return;
          window.__ncupCheckoutInterceptorInstalled = true;

          function sendToFlutter(data) {
            try {
              if (!data || typeof data !== 'object') return;
              if (data.type === 'newTab' && data.url) {
                console.log('[NCUP checkout interceptor] newTab:', data.url);
                if (
                  window.flutter_inappwebview &&
                  window.flutter_inappwebview.callHandler
                ) {
                  window.flutter_inappwebview.callHandler(
                    'NcupCheckoutAction',
                    data
                  );
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] send error', e);
            }
          }

          function tryParseMaybeJson(value) {
            try {
              if (!value) return null;
              if (typeof value === 'object') {
                return value;
              }
              if (typeof value === 'string') {
                return JSON.parse(value);
              }
              return null;
            } catch (e) {
              return null;
            }
          }

          function tryHandlePayload(payload) {
            try {
              var data = tryParseMaybeJson(payload);
              if (!data) return;

              if (Array.isArray(data)) {
                data.forEach(function(item) {
                  if (item && item.type === 'newTab' && item.url) {
                    sendToFlutter(item);
                  }
                });
                return;
              }

              if (data.type === 'newTab' && data.url) {
                sendToFlutter(data);
                return;
              }

              if (data.savedata) {
                var saved = tryParseMaybeJson(data.savedata);
                if (saved && saved.type === 'newTab' && saved.url) {
                  sendToFlutter(saved);
                  return;
                }
              }

              if (data.data) {
                var nested = tryParseMaybeJson(data.data);
                if (nested && nested.type === 'newTab' && nested.url) {
                  sendToFlutter(nested);
                  return;
                }
              }

              if (data.content) {
                var content = tryParseMaybeJson(data.content);
                if (content && content.type === 'newTab' && content.url) {
                  sendToFlutter(content);
                  return;
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] handle error', e);
            }
          }

          var originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function() {
              return originalFetch.apply(this, arguments).then(function(response) {
                try {
                  var cloned = response.clone();
                  cloned.text().then(function(text) {
                    tryHandlePayload(text);
                  }).catch(function() {});
                } catch (e) {}
                return response;
              });
            };
          }

          var OriginalXHR = window.XMLHttpRequest;
          if (OriginalXHR) {
            window.XMLHttpRequest = function() {
              var xhr = new OriginalXHR();
              var originalOpen = xhr.open;
              var originalSend = xhr.send;

              xhr.open = function() {
                return originalOpen.apply(xhr, arguments);
              };

              xhr.send = function() {
                xhr.addEventListener('load', function() {
                  try {
                    tryHandlePayload(xhr.responseText);
                  } catch (e) {}
                });
                return originalSend.apply(xhr, arguments);
              };

              return xhr;
            };
          }

          var originalOpen = window.open;
          window.open = function(url, target, features) {
            try {
              console.log('[NCUP window.open intercepted]', url, target, features);
            } catch (e) {}

            if (originalOpen) {
              return originalOpen.apply(window, arguments);
            }
            return null;
          };
        })();
      ''',
    );
  }

  Future<void> _installLocalStorageHook(
      InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installLocalStorageHook',
      source: r'''
        (function() {
          if (window.__ncupLocalStorageHookInstalled) return;
          window.__ncupLocalStorageHookInstalled = true;

          try {
            var originalSetItem = window.localStorage.setItem;
            window.localStorage.setItem = function(key, value) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler('NcupLocalStorageSetItem', {
                    key: String(key),
                    value: String(value)
                  });
                }
              } catch (e) {
                console.log('Ncup localStorage hook error', e);
              }
              return originalSetItem.apply(this, arguments);
            };
          } catch (e) {
            console.log('Ncup localStorage hook init error', e);
          }
        })();
      ''',
    );
  }

  Future<void> _safeInstallAll(
      InAppWebViewController? controller, {
        required String label,
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    // хуки ставим только если с сервера пришёл fpscashier=true
    if (!retrogoDeviceProfileInstance.safecasher) {
      print('WERLOG: safeInstallAll skipped ($label) because fpscashier=false');
      return;
    }

    try {
      await Future<void>.delayed(
        label == 'popup'
            ? const Duration(milliseconds: 550)
            : const Duration(milliseconds: 250),
      );
      if (!mounted) return;
      await _installJsErrorLogger(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installPostMessageBridge(controller, label: label);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installCheckoutInterceptor(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installLocalStorageHook(controller);
    } catch (e) {
      print('WERLOG: safeInstallAll error label=$label error=$e');
    }
  }

  void _scheduleSafeInstall(
      InAppWebViewController controller, {
        required String label,
      }) {
    if (label == 'popup') {
      _popupInstallTimer?.cancel();
      _popupInstallTimer =
          Timer(const Duration(milliseconds: 450), () async {
            if (!mounted) return;
            await _safeInstallAll(controller, label: label);
          });
    } else {
      _parentInstallTimer?.cancel();
      _parentInstallTimer =
          Timer(const Duration(milliseconds: 250), () async {
            if (!mounted) return;
            await _safeInstallAll(controller, label: label);
          });
    }
  }

  Map<String, dynamic>? _tryDecodeMap(dynamic value) {
    try {
      if (value == null) return null;
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      if (value is String) {
        final String trimmed = value.trim();
        if (trimmed.isEmpty) return null;
        final dynamic decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _openExternalForJsonNewTab(Uri uri) async {
    if (_isAboutBlankUri(uri)) return false;

    final String url = uri.toString();

    if (_handledNewTabUrls.contains(url)) {
      print('WERLOG: duplicate JSON newTab ignored url=$url');
      return true;
    }

    _handledNewTabUrls.add(url);

    if (_isOpeningExternalNewTab) {
      print('WERLOG: external newTab already opening, ignored url=$url');
      return false;
    }

    _isOpeningExternalNewTab = true;

    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      print('WERLOG: JSON newTab external launched=$launched url=$url');
      return launched;
    } catch (e) {
      print('WERLOG: JSON newTab external error=$e url=$url');
      return false;
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        _isOpeningExternalNewTab = false;
      });
    }
  }

  Future<bool> _handleCheckoutAction(dynamic rawPayload) async {
    try {
      Map<String, dynamic>? data = _tryDecodeMap(rawPayload);
      if (data == null) return false;

      if (data.containsKey('savedata')) {
        final Map<String, dynamic>? savedataMap =
        _tryDecodeMap(data['savedata']);
        if (savedataMap != null) {
          data = savedataMap;
        }
      }

      if (data.containsKey('data')) {
        final Map<String, dynamic>? dataMap = _tryDecodeMap(data['data']);
        if (dataMap != null &&
            dataMap['type']?.toString() == 'newTab' &&
            (dataMap['url']?.toString() ?? '').isNotEmpty) {
          data = dataMap;
        }
      }

      if (data.containsKey('content')) {
        final Map<String, dynamic>? contentMap =
        _tryDecodeMap(data['content']);
        if (contentMap != null &&
            contentMap['type']?.toString() == 'newTab' &&
            (contentMap['url']?.toString() ?? '').isNotEmpty) {
          data = contentMap;
        }
      }

      final String type = data['type']?.toString() ?? '';
      final String url = data['url']?.toString() ?? '';

      if (type == 'newTab' && url.isNotEmpty) {
        final Uri? uri = Uri.tryParse(url);
        if (uri == null || _isAboutBlankUri(uri)) {
          print('WERLOG: invalid JSON newTab uri=$url');
          return false;
        }

        print('WERLOG: handle JSON newTab url=$url');
        await _openExternalForJsonNewTab(uri);
        return true;
      }

      return false;
    } catch (e) {
      print('WERLOG: handleCheckoutAction error: $e');
      return false;
    }
  }

  Future<bool> _onCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction request,
      ) async {
    final Uri? retrogoUri = request.request.url;
    final String urlString = retrogoUri?.toString() ?? '';

    print(
      'WERLOG: MAIN onCreateWindow '
          'windowId=${request.windowId} '
          'url=$urlString '
          'isDialog=${request.isDialog} '
          'hasGesture=${request.hasGesture}',
    );

    // Telegram / Wallet из window.open — сразу во внешний браузер
    if (await retrogoHandleForcedExternal(retrogoUri)) {
      return false;
    }

    if (retrogoUri != null) {
      _currentUrl = retrogoUri.toString();
      await _updateBackButtonVisibility();

      if (_isGoogleUrl(retrogoUri)) {}

      if (retrogoIsBankScheme(retrogoUri) ||
          ((retrogoUri.scheme == 'http' || retrogoUri.scheme == 'https') &&
              retrogoIsBankDomain(retrogoUri))) {
        await retrogoOpenBank(retrogoUri);
        return false;
      }

      if (retrogoIsBareEmail(retrogoUri)) {
        final Uri retrogoMailto = retrogoToMailto(retrogoUri);
        await retrogoOpenMailExternal(retrogoMailto);
        return false;
      }

      final String retrogoScheme = retrogoUri.scheme.toLowerCase();

      if (retrogoScheme == 'mailto') {
        await retrogoOpenMailExternal(retrogoUri);
        return false;
      }

      if (retrogoScheme == 'tel') {
        await launchUrl(retrogoUri, mode: LaunchMode.externalApplication);
        return false;
      }

      final String host = retrogoUri.host.toLowerCase();
      final bool retrogoIsSocial = host.endsWith('facebook.com') ||
          host.endsWith('instagram.com') ||
          host.endsWith('twitter.com') ||
          host.endsWith('x.com');

      if (retrogoIsSocial) {
        await retrogoOpenExternal(retrogoUri);
        return false;
      }

      if (retrogoIsPlatformLink(retrogoUri)) {
        final Uri retrogoWebUri = retrogoHttpizePlatformUri(retrogoUri);
        await retrogoOpenExternal(retrogoWebUri);
        return false;
      }
    }

    if (!mounted) return false;

    setState(() {
      _popupCreateAction = request;
      _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
          ? urlString
          : null;
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });

    return true;
  }

  Future<bool> _onPopupCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction createWindowAction,
      ) async {
    final Uri? uri = createWindowAction.request.url;
    final String urlString = uri?.toString() ?? '';

    print(
      'WERLOG: POPUP onCreateWindow '
          'windowId=${createWindowAction.windowId} '
          'url=$urlString',
    );

    if (await retrogoHandleForcedExternal(uri)) {
      return false;
    }

    if (!mounted) return false;

    if (createWindowAction.windowId != null) {
      setState(() {
        _popupCreateAction = createWindowAction;
        _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
            ? urlString
            : _popupUrl;
        _popupCurrentUrl = _popupUrl;
        _isPopupVisible = true;
      });
      return true;
    }

    if (urlString.isNotEmpty && !_isAboutBlankUrl(urlString)) {
      try {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(urlString)),
        );
      } catch (e) {
        print('WERLOG: popup inner window.open load error: $e url=$urlString');
      }
    }

    return false;
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      retrogoPopupWebViewController = null;
    });
  }

  Future<void> _closePopupAndNotifyParent({
    String reason = 'closed_by_user',
  }) async {
    try {
      await retrogoWebViewController?.evaluateJavascript(
        source: '''
          try {
            window.dispatchEvent(new MessageEvent('message', {
              data: ${jsonEncode({
          'type': 'ncup_popup_closed',
          'reason': reason,
        })},
              origin: window.location.origin
            }));
          } catch(e) {
            console.log('ncup popup close notify failed', e);
          }
        ''',
      );
    } catch (e) {
      print('WERLOG: closePopup notify parent error: $e');
    }
    _closePopup();
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = retrogoPopupWebViewController;
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
    } catch (e) {
      print('WERLOG: _refreshPopupCanGoBack error: $e');
    }
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = retrogoPopupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          _refreshPopupCanGoBack();
        });
      } else {
        await _closePopupAndNotifyParent(reason: 'popup_back_no_history');
      }
    } catch (e) {
      print('WERLOG: _handlePopupBackPressed error: $e');
      _closePopup();
    }
  }

  bool _isCurrentPopupInWhitelist() {
    if (!_isPopupVisible) return false;
    final String popupUrlForCheck = _popupCurrentUrl ?? _popupUrl ?? '';
    return _matchesButtonWhitelist(popupUrlForCheck);
  }

  Widget _buildPopupWebView() {
    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool showBackArrow = !popupInWhitelist && _popupCanGoBack;
    final bool showCloseButton = !popupInWhitelist && !_popupCanGoBack;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            if (!popupInWhitelist) ...[
              SafeArea(
                bottom: false,
                child: Container(
                  color: Colors.black,
                  child: Row(
                    children: [
                      if (showBackArrow)
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white),
                          onPressed: _handlePopupBackPressed,
                        )
                      else if (showCloseButton)
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () {
                            _closePopupAndNotifyParent(reason: 'close_button');
                          },
                        ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
            ],
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null) && _popupUrl != null
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupWebViewSettings(),
                onWebViewCreated:
                    (InAppWebViewController popupController) async {
                  retrogoPopupWebViewController = popupController;

                  print(
                    'WERLOG: popup created '
                        'windowId=${_popupCreateAction?.windowId} '
                        'initialUrl=${_popupUrl ?? _popupCreateAction?.request.url}',
                  );

                  final String popupInitUrl =
                      _popupUrl ?? _popupCreateAction?.request.url?.toString() ?? '';
                  if (popupInitUrl.isNotEmpty) {
                    final Uri? popupUri = Uri.tryParse(popupInitUrl);
                    if (popupUri != null && _isGoogleUrl(popupUri)) {
                      await _applyGoogleUserAgentForPopup();
                    }
                  }

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupLocalStorageSetItem',
                    callback: (List<dynamic> args) async {
                      try {
                        if (args.isEmpty) return null;
                        final dynamic raw = args.first;
                        if (raw is Map) {
                          final String key = raw['key']?.toString() ?? '';
                          final String value = raw['value']?.toString() ?? '';
                          if (key.isNotEmpty) {
                            final SharedPreferences prefs =
                            await SharedPreferences.getInstance();
                            await prefs.setString(key, value);
                            RetrogoLoggerService().retrogoLogInfo(
                                'NcupLocalStorageSetItem (popup): saved key="$key" len=${value.length}');
                          }
                        }
                      } catch (e, st) {
                        RetrogoLoggerService().retrogoLogError(
                            'NcupLocalStorageSetItem popup handler error: $e\n$st');
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupCheckoutAction',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupCheckoutAction args=$args');
                      if (args.isNotEmpty) {
                        await _handleCheckoutAction(args.first);
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupPostMessage',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupPostMessage args=$args');
                      if (args.isNotEmpty) {
                        final dynamic first = args.first;
                        if (first is Map && first['data'] != null) {
                          await _handleCheckoutAction(first['data']);
                        } else {
                          await _handleCheckoutAction(first);
                        }
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupJSLogger',
                    callback: (List<dynamic> args) {
                      print('WERLOG: POPUP JS error payload: $args');
                      return null;
                    },
                  );
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStart: (controller, uri) async {
                  print('WERLOG: popup onLoadStart url=$uri');
                  if (uri != null &&
                      (retrogoIsTelegramUri(uri) || retrogoIsWalletUri(uri))) {
                    try {
                      await controller.stopLoading();
                    } catch (_) {}
                    await retrogoHandleForcedExternal(uri);
                    return;
                  }
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (_isGoogleUrl(uri)) {
                      await _applyGoogleUserAgentForPopup();
                    }

                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onLoadStop: (controller, uri) async {
                  print('WERLOG: popup onLoadStop url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                      });
                    }
                  }
                  if (!_isAboutBlankUri(uri)) {
                    _scheduleSafeInstall(controller, label: 'popup');
                  }
                  _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory: (controller, url, isReload) async {
                  if (url != null && !_isAboutBlankUri(url)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = url.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onCreateWindow: _onPopupCreateWindowHandler,
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
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction navigationAction,
                    ) async {
                  final Uri? uri = navigationAction.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isAboutBlankUri(uri)) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  // Telegram / Wallet — сразу во внешний браузер
                  if (await retrogoHandleForcedExternal(uri)) {
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (_isGoogleUrl(uri)) {
                    await _applyGoogleUserAgentForPopup();
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (retrogoIsBareEmail(uri)) {
                    final Uri mailto = retrogoToMailto(uri);
                    await retrogoOpenMailExternal(mailto);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await retrogoOpenMailExternal(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (retrogoIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          retrogoIsBankDomain(uri))) {
                    await retrogoOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    print(
                      'WERLOG: popup blocked non-http/https scheme=$scheme url=$uri',
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  const blockedHosts = [
                    'onelink.me',
                    'app.myapp.retrogo.team',
                  ];
                  final host = uri.host;

                  if (blockedHosts.any((h) => host == h || host.endsWith('.$h'))) {
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  print('WERLOG: popup onCloseWindow');
                  _closePopup();
                },
                onLoadError: (controller, uri, code, message) async {
                  print(
                    'WERLOG: popup onLoadError url=$uri code=$code msg=$message',
                  );
                },
                onReceivedError: (controller, request, error) async {
                  print(
                    'WERLOG: popup onReceivedError '
                        'url=${request.url} '
                        'type=${error.type} '
                        'desc=${error.description}',
                  );
                },
                onReceivedHttpError:
                    (controller, request, errorResponse) async {
                  print(
                    'WERLOG: popup onReceivedHttpError '
                        'url=${request.url} '
                        'status=${errorResponse.statusCode} '
                        'reason=${errorResponse.reasonPhrase}',
                  );
                },
                onConsoleMessage: (controller, consoleMessage) {
                  print(
                    'WERLOG: popup console: '
                        '${consoleMessage.messageLevel} ${consoleMessage.message}',
                  );
                },
                onDownloadStartRequest: (controller, req) async {
                  print(
                      'WERLOG: popup download for url=${req.url}, opening external');
                  await retrogoOpenExternal(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    retrogoBindNotificationTap();

    final Color bgColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget webView = Stack(
      children: <Widget>[
        if (retrogoCoverVisible)
          const Center(child:RetroLoaderScreen())
        else
          Container(
            color: bgColor,
            child: Stack(
              children: <Widget>[
                InAppWebView(
                  key: ValueKey<int>(retrogoWebViewKeyCounter),
                  initialSettings: _mainWebViewSettings(),
                  initialUrlRequest: URLRequest(
                    url: WebUri(retrogoHomeUrl),
                  ),
                  onWebViewCreated:
                      (InAppWebViewController controller) async {
                    retrogoWebViewController = controller;
                    _currentUrl = retrogoHomeUrl;

                    retrogoBosunInstance ??= RetrogoBosunViewModel(
                      retrogoDeviceProfileInstance:
                      retrogoDeviceProfileInstance,
                      retrogoAnalyticsSpyInstance:
                      retrogoAnalyticsSpyInstance,
                    );

                    retrogoCourier ??= RetrogoCourierService(
                      retrogoBosun: retrogoBosunInstance!,
                      retrogoGetWebViewController: () =>
                      retrogoWebViewController,
                    );

                    try {
                      final ua = await controller.evaluateJavascript(
                        source: "navigator.userAgent",
                      );
                      if (ua is String && ua.trim().isNotEmpty) {
                        _baseUserAgent = ua.trim();
                        _currentUserAgent = _baseUserAgent!;
                        retrogoDeviceProfileInstance.retrogoBaseUserAgent =
                            _baseUserAgent;
                        RetrogoLoggerService().retrogoLogInfo(
                            'Initial WebView User-Agent: $_baseUserAgent');
                        print(
                            '[UA] INITIAL WEBVIEW USER AGENT: $_baseUserAgent');
                      }
                    } catch (e) {
                      RetrogoLoggerService().retrogoLogWarn(
                          'Failed to read navigator.userAgent on create: $e');
                    }

                    await _applyNormalUserAgentIfNeeded();

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupLocalStorageSetItem',
                      callback: (List<dynamic> args) async {
                        try {
                          if (args.isEmpty) return null;
                          final dynamic raw = args.first;
                          if (raw is Map) {
                            final String key =
                                raw['key']?.toString() ?? '';
                            final String value =
                                raw['value']?.toString() ?? '';
                            if (key.isNotEmpty) {
                              final SharedPreferences prefs =
                              await SharedPreferences.getInstance();
                              await prefs.setString(key, value);
                              RetrogoLoggerService().retrogoLogInfo(
                                  'NcupLocalStorageSetItem (main): saved key="$key" len=${value.length}');
                            }
                          }
                        } catch (e, st) {
                          RetrogoLoggerService().retrogoLogError(
                              'NcupLocalStorageSetItem main handler error: $e\n$st');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'onServerResponse',
                      callback: (List<dynamic> args) async {
                        if (args.isEmpty) return null;

                        print("Get Data server $args");

                        try {
                          dynamic first = args[0];

                          if (first is List && first.isNotEmpty) {
                            first = first.first;
                          }

                          final bool handled =
                          await _handleCheckoutAction(first);
                          if (handled) {}

                          if (first is Map) {
                            final Map<dynamic, dynamic> root = first;

                            if (root['savedata'] != null) {
                              retrogoHandleServerSavedata(
                                  root['savedata'].toString());
                              await _handleCheckoutAction(root['savedata']);
                            }

                            _updateExtraDataFromServerPayload(root);
                            _updateSafeAreaFromServerPayload(root);
                            await _updateUserAgentFromServerPayload(root);

                            await _applyNormalUserAgentIfNeeded();

                            try {
                              if (!_loadedJsExecutedOnce) {
                                final dynamic adataRaw = root['adata'];
                                if (adataRaw is Map) {
                                  final Map adata = adataRaw;
                                  final dynamic loadedJsRaw =
                                  adata['loadedjs'];
                                  if (loadedJsRaw != null) {
                                    final String loadedJs =
                                    loadedJsRaw.toString().trim();
                                    if (loadedJs.isNotEmpty) {
                                      _pendingLoadedJs = loadedJs;
                                      RetrogoLoggerService().retrogoLogInfo(
                                        'loadedjs received, will execute ONCE after 6 seconds',
                                      );

                                      Future<void>.delayed(
                                        const Duration(seconds: 6),
                                            () async {
                                          if (!mounted) return;
                                          if (_loadedJsExecutedOnce) {
                                            RetrogoLoggerService()
                                                .retrogoLogInfo(
                                                'Skipping loadedjs: already executed once');
                                            return;
                                          }
                                          if (retrogoWebViewController ==
                                              null) {
                                            RetrogoLoggerService()
                                                .retrogoLogWarn(
                                                'Skipping loadedjs execution: controller is null');
                                            return;
                                          }
                                          final String? jsToRun =
                                              _pendingLoadedJs;
                                          if (jsToRun == null ||
                                              jsToRun.isEmpty) {
                                            return;
                                          }
                                          RetrogoLoggerService()
                                              .retrogoLogInfo(
                                              'Executing loadedjs from server payload (ONCE, delayed 6s)');
                                          try {
                                            await retrogoWebViewController
                                                ?.evaluateJavascript(
                                              source: jsToRun,
                                            );
                                            _loadedJsExecutedOnce = true;
                                          } catch (e, st) {
                                            RetrogoLoggerService()
                                                .retrogoLogError(
                                                'Error executing delayed loadedjs: $e\n$st');
                                          }
                                        },
                                      );
                                    }
                                  }
                                }
                              } else {
                                RetrogoLoggerService().retrogoLogInfo(
                                    'loadedjs ignored: already executed once earlier');
                              }
                            } catch (e, st) {
                              RetrogoLoggerService().retrogoLogError(
                                  'Error scheduling loadedjs: $e\n$st');
                            }
                          }
                        } catch (e, st) {
                          print('onServerResponse error: $e\n$st');
                        }

                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupCheckoutAction',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupCheckoutAction args=$args');
                          if (args.isNotEmpty) {
                            await _handleCheckoutAction(args.first);
                          }
                        } catch (e) {
                          print(
                              'WERLOG: MAIN NcupCheckoutAction error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupJSLogger',
                      callback: (List<dynamic> args) {
                        try {
                          final dynamic payload =
                          args.isNotEmpty ? args.first : null;
                          print('WERLOG: MAIN JS error payload: $payload');
                        } catch (e) {
                          print('WERLOG: NcupJSLogger handler error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupPostMessage',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupPostMessage args=$args');
                          if (args.isNotEmpty) {
                            final dynamic first = args.first;
                            if (first is Map && first['data'] != null) {
                              await _handleCheckoutAction(first['data']);
                            } else {
                              await _handleCheckoutAction(first);
                            }
                          }
                        } catch (e) {
                          print(
                              'WERLOG: NcupPostMessage handler error: $e');
                        }
                        return null;
                      },
                    );
                  },
                  onPermissionRequest: (controller, request) async {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.GRANT,
                    );
                  },
                  onLoadStart:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      retrogoStartLoadTimestamp =
                          DateTime.now().millisecondsSinceEpoch;
                    });

                    final Uri? retrogoViewUri = uri;
                    if (retrogoViewUri != null &&
                        (retrogoIsTelegramUri(retrogoViewUri) ||
                            retrogoIsWalletUri(retrogoViewUri))) {
                      try {
                        await controller.stopLoading();
                      } catch (_) {}
                      await retrogoHandleForcedExternal(retrogoViewUri);
                      return;
                    }
                    if (retrogoViewUri != null) {
                      _currentUrl = retrogoViewUri.toString();

                      await _switchUserAgentForUrl(retrogoViewUri);

                      await _updateBackButtonVisibility();

                      if (retrogoIsBareEmail(retrogoViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        final Uri retrogoMailto =
                        retrogoToMailto(retrogoViewUri);
                        await retrogoOpenMailExternal(retrogoMailto);
                        return;
                      }

                      final String retrogoScheme =
                      retrogoViewUri.scheme.toLowerCase();

                      if (retrogoScheme == 'mailto') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await retrogoOpenMailExternal(retrogoViewUri);
                        return;
                      }

                      if (retrogoIsBankScheme(retrogoViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await retrogoOpenBank(retrogoViewUri);
                        return;
                      }

                      if (retrogoScheme != 'http' && retrogoScheme != 'https') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                      }
                    }
                  },
                  onLoadError: (
                      InAppWebViewController controller,
                      Uri? uri,
                      int code,
                      String message,
                      ) async {
                    final int retrogoNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String retrogoEvent =
                        'InAppWebViewError(code=$code, message=$message)';

                    await retrogoPostStat(
                      event: retrogoEvent,
                      timeStart: retrogoNow,
                      timeFinish: retrogoNow,
                      url: uri?.toString() ?? '',
                      appSid: retrogoAnalyticsSpyInstance.retrogoAppsFlyerUid,
                      firstPageLoadTs: retrogoFirstPageTimestamp,
                    );
                  },
                  onReceivedError: (
                      InAppWebViewController controller,
                      WebResourceRequest request,
                      WebResourceError error,
                      ) async {
                    final int retrogoNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String retrogoDescription =
                    (error.description ?? '').toString();
                    final String retrogoEvent =
                        'WebResourceError(code=$error, message=$retrogoDescription)';

                    await retrogoPostStat(
                      event: retrogoEvent,
                      timeStart: retrogoNow,
                      timeFinish: retrogoNow,
                      url: request.url?.toString() ?? '',
                      appSid: retrogoAnalyticsSpyInstance.retrogoAppsFlyerUid,
                      firstPageLoadTs: retrogoFirstPageTimestamp,
                    );
                  },
                  onLoadStop:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      retrogoCurrentUrl = uri.toString();
                      _currentUrl = retrogoCurrentUrl;
                    });

                    if (uri != null) {
                      await _switchUserAgentForUrl(uri);
                    }

                    if (!_isAboutBlankUri(uri)) {
                      _scheduleSafeInstall(controller, label: 'parent');
                    }

                    await debugPrintCurrentUserAgent();

                    await _sendAllDataToPageTwice();
                    await _updateBackButtonVisibility();

                    Future<void>.delayed(
                      const Duration(seconds: 20),
                          () {
                        retrogoSendLoadedOnce(
                          url: retrogoCurrentUrl.toString(),
                          timestart: retrogoStartLoadTimestamp,
                        );
                      },
                    );
                  },
                  onUpdateVisitedHistory:
                      (controller, url, isReload) async {
                    if (url != null && !_isAboutBlankUri(url)) {
                      _currentUrl = url.toString();
                      await _updateBackButtonVisibility();
                      await _switchUserAgentForUrl(url);
                    }
                  },
                  shouldOverrideUrlLoading:
                      (InAppWebViewController controller,
                      NavigationAction action) async {
                    final Uri? retrogoUri = action.request.url;
                    if (retrogoUri == null) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    _currentUrl = retrogoUri.toString();
                    await _updateBackButtonVisibility();

                    if (_isAboutBlankUri(retrogoUri)) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    // Telegram / Wallet — сразу во внешний браузер
                    if (await retrogoHandleForcedExternal(retrogoUri)) {
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (_isGoogleUrl(retrogoUri)) {
                      _isCurrentlyOnGoogle = true;
                      await _applyGoogleUserAgent();
                      return NavigationActionPolicy.ALLOW;
                    } else {
                      if (_isCurrentlyOnGoogle) {
                        _isCurrentlyOnGoogle = false;
                      }
                      await _applyNormalUserAgentIfNeeded();
                    }

                    if (retrogoIsBareEmail(retrogoUri)) {
                      final Uri retrogoMailto = retrogoToMailto(retrogoUri);
                      await retrogoOpenMailExternal(retrogoMailto);
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String retrogoScheme =
                    retrogoUri.scheme.toLowerCase();

                    if (retrogoScheme == 'mailto') {
                      await retrogoOpenMailExternal(retrogoUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (retrogoIsBankScheme(retrogoUri)) {
                      await retrogoOpenBank(retrogoUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if ((retrogoScheme == 'http' || retrogoScheme == 'https') &&
                        retrogoIsBankDomain(retrogoUri)) {
                      await retrogoOpenBank(retrogoUri);

                      if (_isAdobeRedirect(retrogoUri)) {
                        if (context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  AdobeRedirectScreen(uri: retrogoUri),
                            ),
                          );
                        }
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (retrogoScheme == 'tel') {
                      await launchUrl(
                        retrogoUri,
                        mode: LaunchMode.externalApplication,
                      );
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String host = retrogoUri.host.toLowerCase();
                    final bool retrogoIsSocial =
                        host.endsWith('facebook.com') ||
                            host.endsWith('instagram.com') ||
                            host.endsWith('twitter.com') ||
                            host.endsWith('x.com');

                    if (retrogoIsSocial) {
                      await retrogoOpenExternal(retrogoUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (retrogoIsPlatformLink(retrogoUri)) {
                      final Uri retrogoWebUri =
                      retrogoHttpizePlatformUri(retrogoUri);
                      await retrogoOpenExternal(retrogoWebUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (retrogoScheme != 'http' && retrogoScheme != 'https') {
                      return NavigationActionPolicy.CANCEL;
                    }

                    return NavigationActionPolicy.ALLOW;
                  },
                  onCreateWindow: _onCreateWindowHandler,
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
                  onCloseWindow: (controller) {
                    print('WERLOG: MAIN onCloseWindow');
                  },
                  onDownloadStartRequest: (
                      InAppWebViewController controller,
                      DownloadStartRequest req,
                      ) async {
                    await retrogoOpenExternal(req.url);
                  },
                  onConsoleMessage: (controller, consoleMessage) {
                    print(
                      'WERLOG: MAIN console: '
                          '${consoleMessage.messageLevel} ${consoleMessage.message}',
                    );
                  },
                ),
                Visibility(
                  visible: !retrogoVeilVisible,
                  child: const Center(child:RetroLoaderScreen()),
                ),
                if (_isPopupVisible &&
                    (_popupUrl != null || _popupCreateAction != null))
                  _buildPopupWebView(),
              ],
            ),
          ),
      ],
    );

    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool whitelistMatch =
        (!_isPopupVisible && _showBackButton) || popupInWhitelist;

    final bool shouldShowTopBackBar =
        whitelistMatch && !_backButtonHiddenAfterTap;

    final Color topBarColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget topBackBar = shouldShowTopBackBar
        ? Container(
      color: topBarColor,
      padding: const EdgeInsets.only(left: 4, right: 4),
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleBackButtonPressed,
          ),
        ],
      ),
    )
        : const SizedBox.shrink();

    final Widget fullScreen = Column(
      children: [
        topBackBar,
        Expanded(child: webView),
      ],
    );

    final Widget body = _safeAreaEnabled
        ? SafeArea(
      child: fullScreen,
    )
        : fullScreen;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: bgColor,
        body: SizedBox.expand(
          child: ColoredBox(
            color: bgColor,
            child: body,
          ),
        ),
      ),
    );
  }

  bool _isAdobeRedirect(Uri uri) {
    final String host = uri.host.toLowerCase();
    return host == 'c00.adobe.com';
  }
}

// ---------------------- Экран для c00.adobe.com ----------------------

class AdobeRedirectScreen extends StatelessWidget {
  final Uri uri;

  const AdobeRedirectScreen({super.key, required this.uri});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF111111),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Go to the App Store and download the app.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                ),
              ),
              SizedBox(height: 24),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// main()
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(retrogoFcmBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tz_data.initializeTimeZones();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RetrogoHall(),
    ),
  );
}