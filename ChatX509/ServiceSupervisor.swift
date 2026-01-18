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
    
    /// Restart all network services in the correct order
    /// 1. MulticastService (Low level transport)
    /// 2. GlobalMessageService (Message listener)
    /// 3. UserDiscoveryService (Presence/Announcement)
    func restartAllServices() async {
        // Run on background thread to prevent Main Thread blocking
        // during synchronous socket operations in MulticastService.
        await Task.detached {
            print("[Supervisor] Restarting all services...")
            
            // 1. Restart Transport Layer
            await MulticastService.shared.restart()
            
            // 2. Restart Message Listener
            await GlobalMessageService.shared.restart()
            
            // 3. Restart Discovery (Announce new identity)
            await UserDiscoveryService.shared.restart()
            
            // 4. Restart Message Sender (Reliable Delivery)
            await MessageSenderService.shared.restart()
            
            print("[Supervisor] All services restarted.")
        }.value
    }
}
