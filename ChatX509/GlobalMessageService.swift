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
                
                // Parse Metadata (Features) regarding file properties
                var finalMime = mimeType
                var finalFilename: String?
                
                for feature in file.data {
                     let key = String(decoding: feature.key.bytes, as: UTF8.self)
                     let val = String(decoding: feature.value.bytes, as: UTF8.self)
                     if key == "filename" {
                         finalFilename = val
                     } else if key == "original-mime" {
                         finalMime = val
                     }
                }
                
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
                
                // Fallback for missing metadata on encrypted files
                if wasEncrypted && finalMime == "application/cms" && finalFilename == nil {
                     finalMime = "text/plain"
                }

                let messageText: String
                if finalMime.hasPrefix("text/") {
                     messageText = String(decoding: payloadData, as: UTF8.self)
                } else {
                     messageText = finalFilename != nil ? "Sent a file: \(finalFilename!)" : "Sent a file"
                }
                
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
                
                // Send ACK (Read Receipt)
                await sendAck(for: msg.id, sender: sender)
                
                print("[GlobalMessage] Received message from \(sender): \(messageText.prefix(50))...")
                
            } catch {
                // Silently ignore non-message data
                continue
            }
        }
    }
    
    // MARK: - ACK Sending
    private func sendAck(for originId: ASN1OctetString, sender: String) async {
        guard let username = await MainActor.run(body: { certificateManager.username }).data(using: .utf8),
              let privateKey = await MainActor.run(body: { certificateManager.currentPrivateKey }) else { return }
        
        // Construct ACK Message
        var idBytes = [UInt8](repeating: 0, count: 16)
        let _ = SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes)
        let idOctet = ASN1OctetString(contentBytes: ArraySlice(idBytes))
        
        let fromOctet = ASN1OctetString(contentBytes: ArraySlice(username))
        let toOctet = ASN1OctetString(contentBytes: ArraySlice(sender.utf8))
        
        let emptyOctet = ASN1OctetString(contentBytes: [])
        
        // Minimal file
        let dummyFile = CHAT_FileDesc(
            id: emptyOctet,
            mime: ASN1OctetString(contentBytes: ArraySlice("text/plain".utf8)),
            payload: try! ASN1Any(derEncoded: [0x05, 0x00]), // NULL
            parentid: emptyOctet,
            data: []
        )
        
        // Sign
         var seqSerializer = DER.Serializer()
         try! seqSerializer.serializeSequenceOf([dummyFile])
         let filesDer = seqSerializer.serializedBytes
         var tbsData = Data(idBytes)
         tbsData.append(Data(fromOctet.bytes))
         tbsData.append(Data(toOctet.bytes))
         tbsData.append(contentsOf: filesDer)
         
        guard let signature = try? privateKey.signature(for: tbsData) else { return }
        let sigOctet = ASN1OctetString(contentBytes: ArraySlice(signature.rawRepresentation))
        
        let ackMsg = CHAT_Message(
            id: idOctet,
            feed_id: .p2p(CHAT_P2P(src: fromOctet, dst: toOctet)),
            signature: sigOctet,
            from: fromOctet,
            to: toOctet,
            created: ArraySlice(String(Int64(Date().timeIntervalSince1970 * 1000)).utf8),
            files: [dummyFile],
            type: CHAT_MessageType(rawValue: 4), // .read
            link: [],
            seenby: emptyOctet,
            repliedby: originId, // Reference the received message ID
            mentioned: [],
            status: CHAT_MessageStatus(rawValue: 0)
        )
        
        let protocolMsg = CHAT_CHATProtocol.message(ackMsg)
        var msgSerializer = DER.Serializer()
        try! msgSerializer.serialize(protocolMsg)
        
        await multicast.send(data: Data(msgSerializer.serializedBytes))
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
