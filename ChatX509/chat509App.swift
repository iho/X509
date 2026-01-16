//
//  chat509App.swift
//  chat509
//
//  Created by Ihor Horobets on 24.12.2025.
//

import SwiftUI
import UserNotifications

// AppDelegate for handling foreground notifications
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    
    // Show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

@main
struct chat509App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("isDarkMode") private var isDarkMode = true
    @Environment(\.scenePhase) var scenePhase
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    init() {
        // Start global message listener
        Task {
            await GlobalMessageService.shared.start()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .background {
                        // Start background task
                        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "FinishNetworkParams") {
                             // Expiration handler
                             UIApplication.shared.endBackgroundTask(backgroundTaskID)
                             backgroundTaskID = .invalid
                        }
                    } else if newPhase == .active {
                        // End background task if any
                        if backgroundTaskID != .invalid {
                            UIApplication.shared.endBackgroundTask(backgroundTaskID)
                            backgroundTaskID = .invalid
                        }
                    }
                }
        }
    }
}
