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

/// Service for automatic discovery of users on the local network
/// Uses UDP multicast to announce presence and discover peers
actor UserDiscoveryService {
    static let shared = UserDiscoveryService()
    
    // Configuration
    private let announceInterval: TimeInterval = 10 // seconds (faster for testing)
    private let staleTimeout: TimeInterval = 60 // Mark offline after 60s without announcement
    
    // State
    private var isRunning = false
    private var announceTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    
    // Discovered users callback
    private var onUserDiscovered: ((DiscoveredUser) -> Void)?
    private var onUserOffline: ((String) -> Void)?
    
    // Track last seen times
    private var lastSeenTimes: [String: Date] = [:]
    
    private let multicast = MulticastService.shared
    private let certificateManager = CertificateManager.shared
    
    private init() {}
    
    // MARK: - Public API
    
    /// Start the discovery service
    func start(onUserDiscovered: @escaping (DiscoveredUser) -> Void, onUserOffline: @escaping (String) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        
        self.onUserDiscovered = onUserDiscovered
        self.onUserOffline = onUserOffline
        
        // Start multicast service
        Task {
            await multicast.start()
        }
        
        // Start announcing presence
        announceTask = Task {
            await announceLoop()
        }
        
        // Start listening for others
        listenTask = Task {
            await listenForPresence()
        }
        
        // Start stale user cleanup
        Task {
            await cleanupLoop()
        }
        
        print("[Discovery] UserDiscoveryService started")
    }
    
    /// Stop the discovery service
    func stop() {
        isRunning = false
        announceTask?.cancel()
        listenTask?.cancel()
        print("UserDiscoveryService stopped")
    }
    
    /// Announce presence immediately (useful when coming online)
    func announceNow() async {
        await announcePresence(status: .online)
    }
    
    // MARK: - Private Implementation
    
    private func announceLoop() async {
        while isRunning {
            await announcePresence(status: .online)
            try? await Task.sleep(nanoseconds: UInt64(announceInterval * 1_000_000_000))
        }
    }
    
    private func announcePresence(status: CHAT_PresenceType) async {
        // Get our identity
        let username = await MainActor.run { certificateManager.username }
        guard !username.isEmpty else {
            print("[Discovery] Skipping announce - no username set")
            return
        }
        
        // Get our certificate (for public key exchange)
        guard let certificate = await MainActor.run(body: { certificateManager.currentCertificate }) else {
            print("[Discovery] Skipping announce - no certificate")
            return
        }
        
        print("[Discovery] Announcing presence for: \(username)")
        
        // Serialize certificate to DER
        var certSerializer = DER.Serializer()
        do {
            try certSerializer.serialize(certificate)
        } catch {
            print("Failed to serialize certificate: \(error)")
            return
        }
        let certDer = certSerializer.serializedBytes
        
        // Build presence message with certificate embedded in nickname field
        // Format: username|base64(certificate)
        let certBase64 = Data(certDer).base64EncodedString()
        let combinedNickname = "\(username)|\(certBase64)"
        
        let presence = CHAT_Presence(
            nickname: ASN1OctetString(contentBytes: ArraySlice(combinedNickname.utf8)),
            status: status
        )
        
        // Wrap in CHATProtocol
        let chatProtocol = CHAT_CHATProtocol.presence(presence)
        
        // Serialize and send
        var serializer = DER.Serializer()
        do {
            try serializer.serialize(chatProtocol)
            let data = Data(serializer.serializedBytes)
            await multicast.send(data: data)
        } catch {
            print("Failed to send presence: \(error)")
        }
    }
    
    private func listenForPresence() async {
        for await data in await multicast.dataStream {
            guard isRunning else { break }
            
            do {
                let proto = try CHAT_CHATProtocol(derEncoded: ArraySlice(data))
                
                // Only process presence messages
                guard case .presence(let presence) = proto else { continue }
                
                // Parse nickname - format: username|base64(certificate)
                let nicknameBytes = Data(presence.nickname.bytes)
                guard let nicknameStr = String(data: nicknameBytes, encoding: .utf8) else { continue }
                
                let parts = nicknameStr.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { continue }
                
                let username = String(parts[0])
                let certBase64 = String(parts[1])
                
                // Skip our own announcements
                let myUsername = await MainActor.run { self.certificateManager.username }
                print("[Discovery] Received presence from '\(username)', my username is '\(myUsername)'")
                if username == myUsername {
                    print("[Discovery] Skipping own announcement")
                    continue
                }
                
                // Decode certificate
                guard let certData = Data(base64Encoded: certBase64) else { continue }
                
                // Parse certificate to extract public key
                let certificate = try AuthenticationFramework_Certificate(derEncoded: ArraySlice(certData))
                let publicKeyData = Data(certificate.toBeSigned.subjectPublicKeyInfo.subjectPublicKey.bytes)
                
                // Convert to CryptoKit public key for encryption
                let encryptionKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKeyData)
                
                // Create discovered user
                let discoveredUser = DiscoveredUser(
                    username: username,
                    certificateData: certData,
                    encryptionPublicKey: encryptionKey,
                    lastSeen: Date(),
                    isOnline: presence.status == .online
                )
                
                // Update last seen
                lastSeenTimes[username] = Date()
                
                print("[Discovery] Discovered user: \(username)")
                
                // Notify callback
                onUserDiscovered?(discoveredUser)
                
            } catch {
                // Silently ignore non-presence messages or parsing errors
                continue
            }
        }
    }
    
    private func cleanupLoop() async {
        while isRunning {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // Check every 30 seconds
            
            let now = Date()
            var staleUsers: [String] = []
            
            for (username, lastSeen) in lastSeenTimes {
                if now.timeIntervalSince(lastSeen) > staleTimeout {
                    staleUsers.append(username)
                }
            }
            
            for username in staleUsers {
                lastSeenTimes.removeValue(forKey: username)
                onUserOffline?(username)
            }
        }
    }
}

// MARK: - Discovered User Model

struct DiscoveredUser: Sendable {
    let username: String
    let certificateData: Data
    let encryptionPublicKey: P256.KeyAgreement.PublicKey
    let lastSeen: Date
    let isOnline: Bool
}
