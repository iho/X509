//
//  GlobalMessageService.swift
//  ChatX509
//
//  Created on 15.01.2026.
//

import Foundation
import SwiftASN1
import CryptoKit
import UserNotifications
import Combine

/// Global service that listens for all incoming messages regardless of which chat is open
/// Updates the user list with message previews and sends local notifications
actor GlobalMessageService {
    static let shared = GlobalMessageService()
    
    private var isRunning = false
    private var listenTask: Task<Void, Never>?
    private let multicast = MulticastService.shared
    private let userStore = ChatUserStore.shared
    private let certificateManager = CertificateManager.shared
    private let cmsService = CMSService.shared
    
    private init() {}
    
    /// Start listening for messages globally
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        // Request notification permission
        Task {
            await requestNotificationPermission()
        }
        
        // Start multicast
        Task {
            await multicast.start()
        }
        
        // Start listening
        listenTask = Task {
            await listenForMessages()
        }
        
        print("[GlobalMessage] Started listening for messages")
    }
    
    func stop() {
        isRunning = false
        listenTask?.cancel()
        print("[GlobalMessage] Stopped")
    }
    
    private func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            print("[GlobalMessage] Notification permission: \(granted)")
        } catch {
            print("[GlobalMessage] Notification permission error: \(error)")
        }
    }
    
    private func listenForMessages() async {
        for await data in await multicast.dataStream {
            guard isRunning else { break }
            
            do {
                let proto = try CHAT_CHATProtocol(derEncoded: ArraySlice(data))
                
                // Only process messages (not presence)
                guard case .message(let msg) = proto else { continue }
                
                // Extract sender
                let sender = String(decoding: msg.from.bytes, as: UTF8.self)
                
                // Skip our own messages
                let myUsername = await MainActor.run { certificateManager.username }
                if sender == myUsername { continue }
                
                // Check if message is for us
                let recipient = String(decoding: msg.to.bytes, as: UTF8.self)
                if recipient != "broadcast" && recipient != myUsername { continue }
                
                // Extract content
                guard let file = msg.files.first else { continue }
                
                // Get MIME type and payload
                let mimeBytes = Data(file.mime.bytes)
                let mimeType = String(decoding: mimeBytes, as: UTF8.self)
                
                var anySerializer = DER.Serializer()
                try anySerializer.serialize(file.payload)
                let contentOctet = try ASN1OctetString(derEncoded: anySerializer.serializedBytes)
                var payloadData = Data(contentOctet.bytes)
                var wasEncrypted = false
                
                // Decrypt if CMS encrypted
                if mimeType == "application/cms" {
                    if let signingKey = await MainActor.run(body: { certificateManager.currentPrivateKey }) {
                        do {
                            let keyData = signingKey.rawRepresentation
                            let decryptionKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: keyData)
                            payloadData = try await cmsService.decrypt(envelopedData: payloadData, privateKey: decryptionKey)
                            wasEncrypted = true
                        } catch {
                            print("[GlobalMessage] Decryption failed: \(error)")
                            continue
                        }
                    }
                }
                
                let messageText = String(decoding: payloadData, as: UTF8.self)
                
                // Extract message ID
                let idData = Data(msg.id.bytes)
                let msgId: UUID
                if idData.count == 16 {
                    msgId = UUID(uuid: (idData[0], idData[1], idData[2], idData[3], idData[4], idData[5], idData[6], idData[7], idData[8], idData[9], idData[10], idData[11], idData[12], idData[13], idData[14], idData[15]))
                } else {
                    msgId = UUID()
                }
                
                // Update user in store with last message and persist to chat
                await MainActor.run {
                    updateUserWithMessage(sender: sender, message: messageText, msgId: msgId, wasEncrypted: wasEncrypted)
                }
                
                // Send local notification
                await sendLocalNotification(from: sender, message: messageText)
                
                print("[GlobalMessage] Received message from \(sender): \(messageText.prefix(50))...")
                
            } catch {
                // Silently ignore non-message data
                continue
            }
        }
    }
    
    @MainActor
    private func updateUserWithMessage(sender: String, message: String, msgId: UUID, wasEncrypted: Bool) {
        var user: ChatUser
        
        if let index = userStore.users.firstIndex(where: { $0.name == sender }) {
            // Update existing user
            userStore.users[index].lastMessage = message
            userStore.users[index].lastMessageDate = Date()
            userStore.users[index].unreadCount += 1
            user = userStore.users[index]
            userStore.objectWillChange.send()
        } else {
            // Create new user
            user = ChatUser(
                name: sender,
                certificateSubject: "CN=\(sender)",
                lastMessage: message,
                lastMessageDate: Date(),
                unreadCount: 1,
                isOnline: true,
                isDiscovered: true
            )
            userStore.users.append(user)
        }
        
        // Save message to the chat's storage so it appears when chat is opened
        let chatMessage = ChatMessage(
            id: msgId,
            content: message,
            timestamp: Date(),
            isFromMe: false,
            senderName: sender,
            isDelivered: true,
            isRead: false,
            isEncrypted: wasEncrypted
        )
        ChatMessageStore.saveMessageToChat(userId: user.id, message: chatMessage)
    }
    
    private func sendLocalNotification(from sender: String, message: String) async {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = message
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Immediate
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[GlobalMessage] Failed to send notification: \(error)")
        }
    }
}
