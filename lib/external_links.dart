// ============================================================================
// Ссылки, которые всегда должны уходить из WebView наружу:
//  • Telegram (бот / канал / tg://) — сразу во внешнее приложение / браузер
//  • Wallet-карточки (Apple Wallet .pkpass, Google Wallet) — сразу в Safari,
//    т.к. WKWebView не умеет добавлять пассы в Wallet.
// ============================================================================

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

const Set<String> _kTelegramHosts = <String>{
  't.me',
  'telegram.me',
  'telegram.dog',
  'telegram.org',
};

const Set<String> _kWalletMimeTypes = <String>{
  'application/vnd.apple.pkpass',
  'application/vnd.apple.pkpasses',
  'application/vnd-com.apple.pkpass',
};

const List<String> _kWalletHosts = <String>[
  'pay.google.com',
  'wallet.google.com',
  'wallet.apple.com',
  'walletpasses.io',
  'passkit.com',
  'pub1.pskt.io',
  'pskt.io',
  'passcreator.com',
  'passslot.com',
];

const List<String> _kWalletUrlMarkers = <String>[
  '.pkpass',
  '.pkpasses',
  'pkpass',
  'add-to-wallet',
  'addtowallet',
  'add_to_wallet',
  'apple-wallet',
  'applewallet',
  'apple_wallet',
  'google-wallet',
  'googlewallet',
  'gp/v/save',
];

bool _hostMatches(String host, String target) =>
    host == target || host.endsWith('.$target');

/// tg://..., telegram://..., https://t.me/..., https://telegram.me/...
bool retrogoIsTelegramUri(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  if (scheme == 'tg' || scheme == 'telegram') return true;
  if (scheme == 'http' || scheme == 'https') {
    final String host = uri.host.toLowerCase();
    return _kTelegramHosts.any((h) => _hostMatches(host, h));
  }
  return false;
}

/// Ссылка на добавление карточки в Wallet (Apple / Google).
bool retrogoIsWalletUri(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  if (scheme == 'shoebox' || scheme == 'wallet') return true;
  if (scheme != 'http' && scheme != 'https') return false;

  final String host = uri.host.toLowerCase();
  if (_kWalletHosts.any((h) => _hostMatches(host, h))) {
    // pay.google.com используется и для оплаты — берём только save-ссылки.
    if (_hostMatches(host, 'pay.google.com')) {
      return uri.path.toLowerCase().contains('/gp/v/save');
    }
    return true;
  }

  final String lower = uri.toString().toLowerCase();
  return _kWalletUrlMarkers.any(lower.contains);
}

bool retrogoIsWalletMime(String? mimeType) {
  if (mimeType == null) return false;
  return _kWalletMimeTypes.contains(mimeType.toLowerCase().split(';').first.trim());
}

/// tg://resolve?domain=bot&start=x → https://t.me/bot?start=x
Uri retrogoTelegramToHttps(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https') return uri;

  final Map<String, String> qp = uri.queryParameters;
  final String? domain = qp['domain'];
  if (domain != null && domain.isNotEmpty) {
    final Map<String, String> rest = Map<String, String>.from(qp)
      ..remove('domain');
    return Uri.https('t.me', '/$domain', rest.isEmpty ? null : rest);
  }
  final String path = <String>[
    if (uri.host.isNotEmpty && uri.host != 'resolve') uri.host,
    ...uri.pathSegments,
  ].join('/');
  return Uri.https('t.me', '/$path', qp.isEmpty ? null : qp);
}

final Map<String, DateTime> _recentlyOpened = <String, DateTime>{};

/// Защита от двойного открытия (shouldOverride + onCreateWindow + onLoadStart).
bool _isDuplicate(String key) {
  final DateTime now = DateTime.now();
  _recentlyOpened.removeWhere(
      (_, t) => now.difference(t) > const Duration(seconds: 2));
  if (_recentlyOpened.containsKey(key)) return true;
  _recentlyOpened[key] = now;
  return false;
}

Future<bool> _launchExternal(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('WERLOG: external launch error=$e url=$uri');
    return false;
  }
}

/// Telegram: tg:// → приложение Telegram, иначе https://t.me во внешнем
/// браузере (Safari сам предложит открыть Telegram).
Future<bool> retrogoOpenTelegramExternal(Uri uri) async {
  if (_isDuplicate('tg:$uri')) return true;
  final String scheme = uri.scheme.toLowerCase();
  debugPrint('WERLOG: telegram → external url=$uri');

  if (scheme == 'tg' || scheme == 'telegram') {
    if (await _launchExternal(uri)) return true;
  }
  return _launchExternal(retrogoTelegramToHttps(uri));
}

/// Wallet: открываем ту же ссылку во внешнем браузере (Safari / Chrome),
/// где «Добавить в Wallet» работает нативно.
Future<bool> retrogoOpenWalletExternal(Uri uri) async {
  if (_isDuplicate('wallet:$uri')) return true;
  debugPrint('WERLOG: wallet → external browser url=$uri');
  return _launchExternal(uri);
}

/// Единая точка: если ссылка Telegram или Wallet — открывает её снаружи
/// и возвращает true (WebView должен отменить навигацию).
Future<bool> retrogoHandleForcedExternal(Uri? uri) async {
  if (uri == null) return false;
  if (retrogoIsTelegramUri(uri)) {
    await retrogoOpenTelegramExternal(uri);
    return true;
  }
  if (retrogoIsWalletUri(uri)) {
    await retrogoOpenWalletExternal(uri);
    return true;
  }
  return false;
}
