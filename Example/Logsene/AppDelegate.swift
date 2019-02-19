import UIKit
import Logsene
import CocoaLumberjack

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

  private func application(application: UIApplication, didFinishLaunchingWithOptions launchOptions: [NSObject: AnyObject]?) -> Bool {
        // NOTE: Set your token below
      try! LogseneInit(appToken: "<yourtoken>", type: "example")
        LLogNSLogMessages()

        // Here we setup CocoaLumberjack to log to both XCode console and Logsene
        DDLog.add(DDTTYLogger.sharedInstance)
        DDLog.add(LogseneLogger())
        DDLogInfo("hello world from CocoaLumberjack!")
        return true
    }
}

