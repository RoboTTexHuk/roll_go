import UIKit
import Flutter
import Firebase
import FirebaseMessaging
import UserNotifications
import AppsFlyerLib

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, MessagingDelegate, AppsFlyerLibDelegate {
  
  // MARK: - AppsFlyer
  private let appsFlyerDevKey = "qsBLmy7dAXDQhowM8V3ca4"
  private let appleAppID = "6776697390"  // без "id"
  private let appsFlyerDeepLinkChannelName = "appsflyer_deeplink_channel"
  
  // MARK: - Channel Names (FCM)
  private enum ChannelName {
    static let app = "com.example.app"
    static let fcmToken = "com.example.fcm/token"
    static let fcmNotification = "com.example.fcm/notification"
    static let fcmPushData = "com.example.fcm/push" // полный userInfo пуша
    static let orientation = "com.example.orientation"
  }

  // MARK: - Properties
  private var appMethodChannel: FlutterMethodChannel?
  private var fcmTokenChannel: FlutterMethodChannel?
  private var fcmNotificationChannel: FlutterMethodChannel?
  private var fcmPushDataChannel: FlutterMethodChannel?
  private var appsFlyerDeepLinkChannel: FlutterMethodChannel?
  private var orientationChannel: FlutterMethodChannel?

  // Messenger неявного Flutter-движка (UIScene life cycle)
  private var flutterMessenger: FlutterBinaryMessenger?

  // MARK: - Orientation lock (per-screen, iPhone + iPad)
  //
  // По умолчанию ничего не заблокировано — все экраны ведут себя как раньше
  // (portrait + landscape, iPad поддерживает multitasking/Stage Manager).
  // Когда Dart-сторона (SimpleWebViewPage2) сообщает через MethodChannel,
  // что она открыта — форсим landscape именно для текущего окна и просим
  // систему немедленно пересчитать ориентацию (iPad иначе игнорирует
  // просто смену supportedInterfaceOrientations "на лету").
  private var forceLandscapeOnly = false
  
  // MARK: - UIApplicationDelegate
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
  ) -> Bool {
    
    // Firebase
    configureFirebase()
    
    // Уведомления
    configureUserNotifications(for: application)
    
    // Flutter-плагины и MethodChannels регистрируются в
    // didInitializeImplicitFlutterEngine (UIScene life cycle).
    
    // AppsFlyer инициализация
    configureAppsFlyer()
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - UIScene: неявный Flutter-движок готов

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    flutterMessenger = messenger
    setupMethodChannels(messenger: messenger)
  }

  private var activeWindowScene: UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  }

  // MARK: - Orientation lock override
  //
  // По умолчанию отдаём стандартный набор (совпадает с тем, что задано в Info.plist).
  // Если forceLandscapeOnly == true — жёстко ограничиваем текущее окно только landscape.
  override func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    if forceLandscapeOnly {
      return [.landscapeLeft, .landscapeRight]
    }
    return defaultOrientationMask()
  }

  private func defaultOrientationMask() -> UIInterfaceOrientationMask {
    if UIDevice.current.userInterfaceIdiom == .pad {
      return [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]
    }
    return [.portrait, .landscapeLeft, .landscapeRight]
  }

  private func applyOrientationLock(_ locked: Bool) {
    forceLandscapeOnly = locked

    let targetMask: UIInterfaceOrientationMask =
      locked ? [.landscapeLeft, .landscapeRight] : defaultOrientationMask()

    if #available(iOS 16.0, *) {
      if let scene = activeWindowScene {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: targetMask)) { error in
          print("Orientation requestGeometryUpdate error: \(error)")
        }
      }
      scene_rootViewController()?.setNeedsUpdateOfSupportedInterfaceOrientations()
    } else {
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  private func scene_rootViewController() -> UIViewController? {
    let scene = activeWindowScene
    let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    return window?.rootViewController
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    // Старт AppsFlyer SDK (должен вызываться при каждом активировании)
    AppsFlyerLib.shared().start()
  }
  
  // MARK: - Universal Links (OneLink / AppsFlyer)
  //
  // ВАЖНО:
  //  - НИГДЕ не открываем браузер / не вызываем openURL.
  //  - Только прокидываем userActivity в Flutter и AppsFlyer.
  //  - Возврат в браузер происходит, как правило, из Flutter‑кода
  //    (launchUrl / WebView по самому OneLink‑URL). Там это и нужно отключить.
  
  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    
    let url = userActivity.webpageURL
    print("UL received in AppDelegate: \(url?.absoluteString ?? "no url")")
    
    // 1. Даем шанс Flutter/плагинам
    let flutterHandled = super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    )
    print("Flutter handled UL: \(flutterHandled)")
    
    // 2. Передаём Universal Link в AppsFlyer
    AppsFlyerLib.shared().continue(userActivity, restorationHandler: nil)
    print("UL forwarded to AppsFlyer")
    
    // 3. Если это наш OneLink‑домен, явно говорим iOS, что обработали
    if let host = url?.host, host == "app.myapp.retrogo.team" {
      // Даже если Flutter вернул false — считаем UL обработанным,
      // чтобы iOS не пыталась открыть что‑то ещё.
      return true
    }
    
    // Для остальных доменов возвращаем флаг Flutter
    return flutterHandled
  }
  
  // MARK: - Firebase / FCM
  
  private func configureFirebase() {
    FirebaseApp.configure()
    Messaging.messaging().delegate = self
  }
  
  // MARK: - Notifications
  
  private func configureUserNotifications(for application: UIApplication) {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    
    let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
    center.requestAuthorization(options: authOptions) { [weak self] granted, error in
      if let error = error {
        print("Ошибка при запросе разрешений: \(error.localizedDescription)")
        return
      }
      
      print("Разрешение на уведомления: \(granted)")
      
      guard granted else { return }
      
      DispatchQueue.main.async {
        application.registerForRemoteNotifications()
      }
      
      Messaging.messaging().token { token, error in
        if let error = error {
          print("Ошибка получения FCM токена: \(error.localizedDescription)")
        } else if let token = token {
          print("FCM токен: \(token)")
          self?.sendTokenToFlutter(token: token)
        }
      }
    }
  }
  
  // MARK: - Method Channels (Flutter)
  
  private func setupMethodChannels(messenger: FlutterBinaryMessenger) {
    // Общий канал приложения
    appMethodChannel = FlutterMethodChannel(
      name: ChannelName.app,
      binaryMessenger: messenger
    )
    
    appMethodChannel?.setMethodCallHandler { [weak self] call, result in
      // Пока ничего не обрабатываем на native‑стороне
      result(FlutterMethodNotImplemented)
      _ = self
    }
    
    // Канал FCM токена
    fcmTokenChannel = FlutterMethodChannel(
      name: ChannelName.fcmToken,
      binaryMessenger: messenger
    )
    
    // Канал уведомлений (onMessage, onNotificationTap)
    fcmNotificationChannel = FlutterMethodChannel(
      name: ChannelName.fcmNotification,
      binaryMessenger: messenger
    )
    
    // Канал "сырых" push‑данных
    fcmPushDataChannel = FlutterMethodChannel(
      name: ChannelName.fcmPushData,
      binaryMessenger: messenger
    )
    
    // Канал диплинков AppsFlyer
    appsFlyerDeepLinkChannel = FlutterMethodChannel(
      name: appsFlyerDeepLinkChannelName,
      binaryMessenger: messenger
    )

    // Канал per-screen лока ориентации (SimpleWebViewPage2)
    orientationChannel = FlutterMethodChannel(
      name: ChannelName.orientation,
      binaryMessenger: messenger
    )
    orientationChannel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "lockLandscape":
        self?.applyOrientationLock(true)
        result(nil)
      case "unlockLandscape":
        self?.applyOrientationLock(false)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
  
  // MARK: - FCM token
  
  private func sendTokenToFlutter(token: String) {
    guard let messenger = flutterMessenger else {
      return
    }
    
    if fcmTokenChannel == nil {
      fcmTokenChannel = FlutterMethodChannel(
        name: ChannelName.fcmToken,
        binaryMessenger: messenger
      )
    }
    
    fcmTokenChannel?.invokeMethod("setToken", arguments: token)
  }
  
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    print("FCM токен обновлён: \(String(describing: fcmToken))")
    if let token = fcmToken {
      sendTokenToFlutter(token: token)
    }
  }
  
  // MARK: - APNs Token
  
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }
  
  // MARK: - Helper: отправка полного userInfo пуша во Flutter
  
  private func sendRawPushDataToFlutter(userInfo: [AnyHashable: Any]) {
    guard let messenger = flutterMessenger else {
      return
    }
    
    if fcmPushDataChannel == nil {
      fcmPushDataChannel = FlutterMethodChannel(
        name: ChannelName.fcmPushData,
        binaryMessenger: messenger
      )
    }
    
    var normalized: [String: Any] = [:]
    for (key, value) in userInfo {
      let k = String(describing: key)
      normalized[k] = value
    }
    
    print("Отправляем полные push‑данные во Flutter: \(normalized)")
    fcmPushDataChannel?.invokeMethod("setPushData", arguments: normalized)
  }
  
  // MARK: - Foreground notification
  
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    print("Пуш в foreground: \(userInfo)")
    
    // только сохраняем данные во Flutter (для поля push), НИЧЕГО не открываем
    sendRawPushDataToFlutter(userInfo: userInfo)
    
    if let messenger = flutterMessenger {
      if fcmNotificationChannel == nil {
        fcmNotificationChannel = FlutterMethodChannel(
          name: ChannelName.fcmNotification,
          binaryMessenger: messenger
        )
      }
      fcmNotificationChannel?.invokeMethod("onMessage", arguments: userInfo)
    }
    
    completionHandler([[.alert, .sound, .badge]])
  }
  
  // MARK: - Notification tap
  
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    print("Тап по пушу: \(userInfo)")
    
    // 1. Полная push‑data → Flutter, чтобы она попала в NcupLastPushData
    sendRawPushDataToFlutter(userInfo: userInfo)
    
    // 2. Извлекаем title/body/uri для onNotificationTap
    let aps = userInfo["aps"] as? [String: Any]
    let alert = aps?["alert"] as? [String: Any]
    let title = alert?["title"] as? String ?? "Без заголовка"
    let body = alert?["body"] as? String ?? "Без текста"
    let uri = userInfo["uri"] as? String ?? "Нет URI"
    
    let notificationData: [String: Any] = [
      "title": title,
      "body": body,
      "uri": uri,
      "data": userInfo
    ]
    
    if let messenger = flutterMessenger {
      if fcmNotificationChannel == nil {
        fcmNotificationChannel = FlutterMethodChannel(
          name: ChannelName.fcmNotification,
          binaryMessenger: messenger
        )
      }
      
      // Во Flutter решается, что показывать, какие экраны/вебы открывать
      fcmNotificationChannel?.invokeMethod("onNotificationTap", arguments: notificationData)
    }
    
    completionHandler()
  }
  
  // MARK: - Background remote notification
  
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable : Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    print("Пуш в background (silent / content-available): \(userInfo)")
    
    // Только передаём данные во Flutter, ничего не открываем.
    sendRawPushDataToFlutter(userInfo: userInfo)
    
    guard let messenger = flutterMessenger else {
      completionHandler(.noData)
      return
    }
    
    if appMethodChannel == nil {
      appMethodChannel = FlutterMethodChannel(
        name: ChannelName.app,
        binaryMessenger: messenger
      )
    }
    
    appMethodChannel?.invokeMethod(
      "handleMessageBackground",
      arguments: ["raw": userInfo]
    ) { _ in
      completionHandler(.newData)
    }
  }
  
  // MARK: - AppsFlyer: конфиг и делегаты
  
  private func configureAppsFlyer() {
    let af = AppsFlyerLib.shared()
    af.appsFlyerDevKey = appsFlyerDevKey
    af.appleAppID = appleAppID
    af.delegate = self
    af.isDebug = true    // выключи в релизе
  }
  
  // Установка/первый запуск, атрибуция
  func onConversionDataSuccess(_ conversionInfo: [AnyHashable : Any]) {
    debugPrint("AF conversion data: \(conversionInfo)")
    handleAppsFlyerDeepLinkData(conversionInfo)
  }
  
  func onConversionDataFail(_ error: Error) {
    debugPrint("AF conversion data error: \(error)")
  }
  
  // Открытие по OneLink, когда приложение уже установлено
  func onAppOpenAttribution(_ attributionData: [AnyHashable : Any]) {
    debugPrint("AF open attribution: \(attributionData)")
    handleAppsFlyerDeepLinkData(attributionData)
  }
  
  func onAppOpenAttributionFailure(_ error: Error) {
    debugPrint("AF open attribution error: \(error)")
  }
  
  // MARK: - Отправка диплинков AppsFlyer во Flutter
  
  private func handleAppsFlyerDeepLinkData(_ data: [AnyHashable: Any]) {
    // Основной ключ: deep_link_value (из OneLink шаблона)
    
    var payload: [String: Any] = [:]
    
    if let deepLinkValue = data["deep_link_value"] as? String {
      payload["deep_link_value"] = deepLinkValue
    }
    
    // Пробрасываем raw‑данные во Flutter (ключи в String)
    var normalized: [String: Any] = [:]
    for (key, value) in data {
      let k = String(describing: key)
      normalized[k] = value
    }
    payload["raw"] = normalized
    
    guard let messenger = flutterMessenger else {
      return
    }
    
    if appsFlyerDeepLinkChannel == nil {
      appsFlyerDeepLinkChannel = FlutterMethodChannel(
        name: appsFlyerDeepLinkChannelName,
        binaryMessenger: messenger
      )
    }
    
    print("Sending AppsFlyer deep link payload to Flutter: \(payload)")
    appsFlyerDeepLinkChannel?.invokeMethod("onDeepLink", arguments: payload)
  }
}


// MARK: - SceneDelegate (UIScene life cycle)
//
// С UIScene Universal Links приходят в SceneDelegate, а не в AppDelegate.
// Сохраняем поведение Flutter (вызываем реализацию FlutterSceneDelegate)
// и дополнительно передаём ссылку в AppsFlyer (OneLink).
class SceneDelegate: FlutterSceneDelegate {

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    // Холодный старт по Universal Link
    for activity in connectionOptions.userActivities
    where activity.activityType == NSUserActivityTypeBrowsingWeb {
      print("UL (cold start) received in SceneDelegate: \(activity.webpageURL?.absoluteString ?? "no url")")
      AppsFlyerLib.shared().continue(activity, restorationHandler: nil)
    }
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    print("UL received in SceneDelegate: \(userActivity.webpageURL?.absoluteString ?? "no url")")
    super.scene(scene, continue: userActivity)
    AppsFlyerLib.shared().continue(userActivity, restorationHandler: nil)
  }
}
