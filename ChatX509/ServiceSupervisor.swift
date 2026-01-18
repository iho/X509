//
//  ServiceSupervisor.swift
//  ChatX509
//
//  Created on 18.01.2026.
//

import Foundation

/// Supervisor responsible for coordinating the lifecycle of all network services.
/// Handles restarts when identity changes to ensure all components pick up the new certificate.
final class ServiceSupervisor: @unchecked Sendable {
    static let shared = ServiceSupervisor()
    
    private init() {}
    
    /// Start all services (Foreground)
    func startAllServices() async {
        await Task.detached {
            print("[Supervisor] Starting all services...")
            
            // 1. Start Transport
            MulticastService.shared.start()
            
            // 2. Start Message Listener
            GlobalMessageService.shared.start()
            
            // 3. Start Discovery
            // (Note: Discovery starts internally via start() calls if configured, 
            // but we can explicitly trigger announce if needed)
            await UserDiscoveryService.shared.announceNow()
            
            // 4. Start Sender
            MessageSenderService.shared.start()
            
            print("[Supervisor] All services started.")
        }.value
    }
    
    /// Stop all services (Background)
    func stopAllServices() {
        print("[Supervisor] Stopping all services...")
        MessageSenderService.shared.stop()
        GlobalMessageService.shared.stop()
        UserDiscoveryService.shared.stop()
        MulticastService.shared.stop()
        print("[Supervisor] All services stopped.")
    }
    
    /// Restart (e.g. Identity Changed)
    func restartAllServices() async {
        stopAllServices()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await startAllServices()
    }
}
