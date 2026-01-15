import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let storageChannelName = "com.pushstr.storage"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let storageChannel = FlutterMethodChannel(
        name: storageChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      storageChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "shareFile":
          guard
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String
          else {
            result(false)
            return
          }
          let fileUrl = URL(fileURLWithPath: path)
          DispatchQueue.main.async {
            let activity = UIActivityViewController(activityItems: [fileUrl], applicationActivities: nil)
            controller.present(activity, animated: true)
            result(true)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
