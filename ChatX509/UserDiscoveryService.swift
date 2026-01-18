//
//  UserDiscoveryService.swift
//  ChatX509
//
//  Created on 15.01.2026.
//

import Foundation
import SwiftASN1
import CryptoKit
import Combine

/// Service for automatic discovery of users on the local network (Announce Looper)
/// "Announce Looper starts on application load... sends 5 identical announcement messages every 10 seconds"
final class UserDiscoveryService: @unchecked Sendable {
    static let shared = UserDiscoveryService()
    
    // Configuration
    private let announceInterval: TimeInterval = 10 // Protocol v1: 10 seconds
    private let burstCount = 5
    private let burstSpacing: UInt64 = 100_000_000 // 100ms
    private let staleTimeout: TimeInterval = 65 // Mark offline after > 60s
    
    // State
    private let serviceLock = NSLock()
    private var isRunning = false
    private var announceTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    
    // Discovered users callback
    private var onUserDiscovered: ((DiscoveredUser) -> Void)?
    private var onUserOffline: ((String, Data?) -> Void)?
    
    // Track last seen times and mapping from username to serial
    private var lastSeenTimes: [String: Date] = [:]
    private var usernameToSerial: [String: Data] = [:]
    
    private let multicast = MulticastService.shared
    private let certificateManager = CertificateManager.shared
    
    private init() {}
    
    // MARK: - Public API
    
    /// Start the discovery service
    func start(onUserDiscovered: @escaping (DiscoveredUser) -> Void, onUserOffline: @escaping (String, Data?) -> Void) {
        serviceLock.lock()
        if isRunning {
            serviceLock.unlock()
            return
        }
        isRunning = true
        
        self.onUserDiscovered = onUserDiscovered
        self.onUserOffline = onUserOffline
        serviceLock.unlock()
        
        // Start multicast service in background
        Task.detached { [weak self] in
            self?.multicast.start()
        }
        
        // Start announcing presence (Announce Looper)
        announceTask = Task.detached { [weak self] in
            await self?.announceLoop()
        }
        
        // Start listening for others (Presence updates)
        listenTask = Task.detached { [weak self] in
            await self?.listenForPresence()
        }
        
        // Start stale user cleanup
        Task.detached { [weak self] in
            await self?.cleanupLoop()
        }
        
        print("[Discovery] UserDiscoveryService started")
    }
    
    /// Stop the discovery service
    func stop() {
        serviceLock.lock()
        isRunning = false
        serviceLock.unlock()
        
        announceTask?.cancel()
        listenTask?.cancel()
        print("UserDiscoveryService stopped")
    }
    
    /// Announce presence immediately (useful when coming online)
    func announceNow() async {
        // Trigger a burst immediately
        await announcePresenceBurst(status: .online)
    }
    
    /// Restart discovery service (e.g. after identity change)
    func restart() async {
        serviceLock.lock()
        let wasRunning = isRunning
        // Save callbacks
        let onDiscovered = self.onUserDiscovered
        let onOffline = self.onUserOffline
        serviceLock.unlock()
        
        if wasRunning {
             stop()
             // Wait for tasks to clear? 
             try? await Task.sleep(nanoseconds: 500_000_000)
             
             if let onDiscovered = onDiscovered, let onOffline = onOffline {
                 start(onUserDiscovered: onDiscovered, onUserOffline: onOffline)
             }
        }
        
        // If not running, just announce once?
        if !wasRunning {
            await announceNow()
        }
    }
    
    // MARK: - Private Implementation
    
    private func announceLoop() async {
        while true {
            // Check running
            serviceLock.lock()
            let running = isRunning
            serviceLock.unlock()
            if !running { break }
            
            await announcePresenceBurst(status: .online)
            
            // Wait 10 seconds
            try? await Task.sleep(nanoseconds: UInt64(announceInterval * 1_000_000_000))
        }
    }
    
    private func announcePresenceBurst(status: CHAT_PresenceType) async {
        // Prepare data ONCE
        // Get our identity
        guard let (username, certificate, _) = certificateManager.getIdentity() else {
             // print("[Discovery] Skipping announce - no identity")
             return
        }
        
        if username.isEmpty { return }
        
        // Serialize certificate
        var certSerializer = DER.Serializer()
        do {
            try certSerializer.serialize(certificate)
        } catch {
            print("Failed to serialize certificate: \(error)")
            return
        }
        let certDer = certSerializer.serializedBytes
        
        // Build presence message
        let certBase64 = Data(certDer).base64EncodedString()
        let combinedNickname = "\(username)|\(certBase64)"
        
        let presence = CHAT_Presence(
            nickname: ASN1OctetString(contentBytes: ArraySlice(combinedNickname.utf8)),
            status: status
        )
        
        let chatProtocol = CHAT_CHATProtocol.presence(presence)
        
        var serializer = DER.Serializer()
        do {
            try serializer.serialize(chatProtocol)
            let data = Data(serializer.serializedBytes)
            
            // Send Burst (5 copies)
            // print("[Discovery] Announcing presence (burst)...")
            for i in 0..<burstCount {
                multicast.send(data: data, address: MulticastService.BROADCAST_GROUP)
                if i < burstCount - 1 {
                    try? await Task.sleep(nanoseconds: burstSpacing)
                }
            }
        } catch {
            print("Failed to send presence: \(error)")
        }
    }
    
    private func listenForPresence() async {
        for await data in multicast.dataStream {
            serviceLock.lock()
            let running = isRunning
            serviceLock.unlock()
            if !running { break }
            
            // print("[Discovery] RX \(data.count) bytes") // Uncomment for verbose stream debug
            
            do {
                let proto = try CHAT_CHATProtocol(derEncoded: ArraySlice(data))
                
                // Only process presence messages
                guard case .presence(let presence) = proto else { continue }
                
                print("[Discovery] Parsed Presence from stream")
                
                // Parse nickname - format: username|base64(certificate)
                let nicknameBytes = Data(presence.nickname.bytes)
                guard let nicknameStr = String(data: nicknameBytes, encoding: .utf8) else {
                     print("[Discovery] FAIL: Nickname decode error")
                     continue
                }
                
                let parts = nicknameStr.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else {
                     print("[Discovery] FAIL: Invalid format: \(nicknameStr)")
                     continue
                }
                
                let username = String(parts[0])
                let certBase64 = String(parts[1])
                
                // Skip our own announcements
                // Note: certificateManager.username is @Published, use safely
                if let (myUsername, _, _) = certificateManager.getIdentity(), username == myUsername {
                    print("[Discovery] Ignoring self-announcement from '\(username)'")
                    continue
                }
                
                // Optimization: Check if we already know this user and they are not stale
                // If known and seen < 60s ago, just update timestamp and skip heavy cert parsing
                serviceLock.lock()
                let lastSeen = lastSeenTimes[username]
                let isKnown = lastSeen != nil
                serviceLock.unlock()
                
                if isKnown, let lastSeen = lastSeen, Date().timeIntervalSince(lastSeen) < 60.0 {
                    // Update timestamp only
                    serviceLock.lock()
                    lastSeenTimes[username] = Date()
                    serviceLock.unlock()
                    // print("[Discovery] Known user '\(username)', skipping cert verification")
                    continue
                }

                print("[Discovery] Processing peer (Full Verify): '\(username)'")
                
                // Decode certificate
                guard let certData = Data(base64Encoded: certBase64) else {
                    print("[Discovery] FAIL: Base64 decode error")
                    continue
                }
                
                // Parse certificate
                let certificate = try AuthenticationFramework_Certificate(derEncoded: ArraySlice(certData))
                let publicKeyData = Data(certificate.toBeSigned.subjectPublicKeyInfo.subjectPublicKey.bytes)
                
                // Convert to CryptoKit public key
                let encryptionKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKeyData)
                
                // Create discovered user
                // Parse Subject (Background)
                let details = certificateManager.extractSubjectDetails(from: certificate)
                var subjectParts: [String] = []
                if let cn = details["Common Name (CN)"] { subjectParts.append("CN=\(cn)") } else { subjectParts.append("CN=\(username)") }
                if let org = details["Organization (O)"] { subjectParts.append("O=\(org)") }
                if let ou = details["Organizational Unit (OU)"] { subjectParts.append("OU=\(ou)") }
                let fullSubject = subjectParts.joined(separator: ", ")
                
                let discoveredUser = DiscoveredUser(
                    username: username,
                    certificateData: certData,
                    certificateSubject: fullSubject,
                    serialNumber: Data(certificate.toBeSigned.serialNumber),
                    encryptionPublicKey: encryptionKey,
                    lastSeen: Date(),
                    isOnline: presence.status == .online
                )
                
                // Update State
                serviceLock.lock()
                let previousSeen = lastSeenTimes[username]
                let previousSerial = usernameToSerial[username]
                
                lastSeenTimes[username] = Date()
                usernameToSerial[username] = Data(certificate.toBeSigned.serialNumber)
                
                let callback = onUserDiscovered
                serviceLock.unlock()
                
                // Throttling Logic:
                // Only notify if:
                // 1. New user (previousSeen == nil)
                // 2. Serial changed (Identity rotation)
                // 3. Status possibly changed (implied by packet arrival? Protocol doesn't have explicit offline packets yet, rely on timeout. But "online" status might be useful if user was offline)
                // 4. Significant time passed (e.g. > 2 seconds) to avoid burst flooding
                
                let isNewUser = previousSeen == nil
                let isSerialChanged = previousSerial != Data(certificate.toBeSigned.serialNumber)
                let isThrottled = previousSeen != nil && Date().timeIntervalSince(previousSeen!) < 10.0
                
                if isNewUser || isSerialChanged || !isThrottled {
                    // Notify callback
                    print("[Discovery] Invoking callback for user: \(discoveredUser.username)")
                    callback?(discoveredUser)
                }
                
            } catch {
                continue
            }
        }
    }
    
    private func cleanupLoop() async {
        while true {
            // Check running
            serviceLock.lock()
            let running = isRunning
            serviceLock.unlock()
            if !running { break }
            
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            
            let now = Date()
            var staleUsers: [String] = []
            
            serviceLock.lock()
            for (username, lastSeen) in lastSeenTimes {
                if now.timeIntervalSince(lastSeen) > staleTimeout {
                    staleUsers.append(username)
                }
            }
            
            var offlineCallback: ((String, Data?) -> Void)? = nil
            
            if !staleUsers.isEmpty {
                 offlineCallback = onUserOffline
                 for username in staleUsers {
                     let serial = usernameToSerial[username]
                     lastSeenTimes.removeValue(forKey: username)
                     usernameToSerial.removeValue(forKey: username)
                     // Call callback outside loop? Or inside if thread safe?
                     // Callback is typically UI update, should be safe or dispatch to Main.
                     // But we are in lock.
                 }
            }
            // Cannot call callback inside lock if it calls back into service or sleeps.
            // Copy data needed for callback.
            let staleInfo: [(String, Data?)] = staleUsers.map { ($0, usernameToSerial[$0]) }
            // Remove serials after mapping
            for user in staleUsers {
                usernameToSerial.removeValue(forKey: user)
            }
            serviceLock.unlock()
            
            if let callback = offlineCallback {
                for (user, serial) in staleInfo {
                    callback(user, serial)
                }
            }
        }
    }
}

// MARK: - Discovered User Model

struct DiscoveredUser: Sendable {
    let username: String
    let certificateData: Data
    let certificateSubject: String // Pre-parsed subject
    let serialNumber: Data
    let encryptionPublicKey: P256.KeyAgreement.PublicKey
    let lastSeen: Date
    let isOnline: Bool
}
