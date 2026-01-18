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

/// Global service that listens for all incoming messages (Receive Looper)
/// Handles:
/// 1. Incoming Announcements -> Updates Roster
/// 2. Incoming Messages -> Decrypts, Saves, Notifies, queues ACK
/// 3. Incoming ACKs -> Notifies SenderService to stop retransmission
final class GlobalMessageService: @unchecked Sendable {
    static let shared = GlobalMessageService()
    
    // Thread-Safety
    private let serviceLock = NSLock()
    private var isRunning = false
    private var listenTask: Task<Void, Never>?
    
    // Dependencies
    private let multicast = MulticastService.shared
    private let userStore = ChatUserStore.shared
    private let certificateManager = CertificateManager.shared
    private let cmsService = CMSService.shared
    
    private init() {}
    
    /// Start listening for messages globally
    func start() {
        serviceLock.lock()
        if isRunning {
            serviceLock.unlock()
            return
        }
        isRunning = true
        serviceLock.unlock()
        
        // Request notification permission
        Task {
            await requestNotificationPermission()
        }
        
        // Start multicast in background
        Task.detached { [weak self] in
            self?.multicast.start()
        }
        
        // Start listening (Receive Looper)
        listenTask = Task.detached { [weak self] in
            await self?.listenForMessages()
        }
        
        print("[GlobalMessage] Started listening for messages")
    }
    
    func stop() {
        serviceLock.lock()
        isRunning = false
        serviceLock.unlock()
        
        listenTask?.cancel()
        print("[GlobalMessage] Stopped")
    }
    
    func restart() async {
        stop()
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s grace
        start()
    }
    
    private func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            print("[GlobalMessage] Notification permission: \(granted)")
        } catch {
            print("[GlobalMessage] Notification permission error: \(error)")
        }
    }
    
    // Deduplication (LRU Cache style or simple set with rotation)
    private var processedMessageIDs: Set<UUID> = []
    
    private func listenForMessages() async {
        // Consume the multicast stream
        for await data in multicast.dataStream {
            // Check running state
            serviceLock.lock()
            let running = isRunning
            serviceLock.unlock()
            if !running { break }
            
            do {
                // Attempt to parse as CHATProtocol (Message/Presence/ACK)
                let proto = try CHAT_CHATProtocol(derEncoded: ArraySlice(data))
                
                switch proto {
                case .message(let msg):
                    // Extract ID early to deduplicate
                    let idData = Data(msg.id.bytes)
                    let msgId: UUID
                    if idData.count == 16 {
                       msgId = UUID(uuid: (idData[0], idData[1], idData[2], idData[3], idData[4], idData[5], idData[6], idData[7], idData[8], idData[9], idData[10], idData[11], idData[12], idData[13], idData[14], idData[15]))
                    } else {
                       msgId = UUID()
                    }
                    
                    // Deduplicate
                    if processedMessageIDs.contains(msgId) {
                        // Already processed this message ID
                        continue
                    }
                    
                    // Add to cache (Naive unlimited growth for now, ideally rotation)
                    // For short sessions this is fine. For long, we need cleanup.
                    // Doing a simple cleanup every 100 messages
                    if processedMessageIDs.count > 500 {
                        processedMessageIDs.removeAll()
                    }
                    processedMessageIDs.insert(msgId)
                    
                    await handleMessage(msg, uuid: msgId)
                    
                case .presence(let pres):
                   // Presence handling can be managed here or by UserDiscoveryService.
                    break
                default:
                    break
                }
                
            } catch {
                continue
            }
        }
    }
    
    // MARK: - Handlers (Protocol v1 Logic)
    
    private func handleMessage(_ msg: CHAT_Message, uuid: UUID) async {
        // Check Type: 4 = ACK (Read Receipt)
        if msg.type.rawValue == 4 {
            await handleAck(msg)
            return
        }
        
        // Normal Message
        // "On Message -> Decrypt/Verify -> Display -> Create ACK -> Add to Sending Queue"
        
        // 1. Decrypt/Verify
        let sender = String(decoding: msg.from.bytes, as: UTF8.self)
        
        // Get our identity safely
        guard let (myUsername, _, myPrivateKey) = certificateManager.getIdentity() else { return }
        
        // Skip own messages
        if sender == myUsername { return }
        
        // Check recipient (Broadcast or Us)
        let recipient = String(decoding: msg.to.bytes, as: UTF8.self)
        if recipient != "broadcast" && recipient != myUsername { return }
        
        // Process Content
        guard let file = msg.files.first else { return }
        
        let mimeBytes = Data(file.mime.bytes)
        let mimeType = String(decoding: mimeBytes, as: UTF8.self)
        
        var anySerializer = DER.Serializer()
        try? anySerializer.serialize(file.payload)
        let contentOctet = try? ASN1OctetString(derEncoded: anySerializer.serializedBytes)
        var payloadData = Data(contentOctet?.bytes ?? [])
        var wasEncrypted = false
        
        var finalMime = mimeType
        var finalFilename: String?
        
        for feature in file.data {
             let key = String(decoding: feature.key.bytes, as: UTF8.self)
             let val = String(decoding: feature.value.bytes, as: UTF8.self)
             if key == "filename" { finalFilename = val }
             else if key == "original-mime" { finalMime = val }
        }
        
        if mimeType == "application/cms" {
            // Decrypt
            do {
                let kaKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: myPrivateKey.rawRepresentation)
                payloadData = try await cmsService.decrypt(envelopedData: payloadData, privateKey: kaKey)
                wasEncrypted = true
            } catch {
                print("[GlobalMessage] Decryption failed: \(error)")
                return
            }
        }
        
        if wasEncrypted && finalMime == "application/cms" && finalFilename == nil {
             finalMime = "text/plain"
        }
        
        let messageText: String
        let attachmentData: Data?
        let isText = finalMime.hasPrefix("text/") && finalFilename == nil
        
        if isText {
             messageText = String(decoding: payloadData, as: UTF8.self)
             attachmentData = nil
        } else {
             messageText = finalFilename != nil ? "Sent a file: \(finalFilename!)" : "Sent a file"
             attachmentData = payloadData
        }
        
        // Message ID (use passed uuid)
        
        // 2. Add to Chat Conversation (Update Store)
        await MainActor.run {
            updateUserWithMessage(
                sender: sender,
                message: messageText,
                msgId: uuid,
                wasEncrypted: wasEncrypted,
                attachmentData: attachmentData,
                attachmentMime: isText ? nil : finalMime,
                attachmentName: finalFilename
            )
        }
        
        // 3. Send Notification
        await sendLocalNotification(from: sender, message: messageText)
        
        // 4. Create ACK and Put in Sending Queue
        await queueAck(for: msg.id, sender: sender, originalMsgId: uuid)
    }
    
    private func handleAck(_ msg: CHAT_Message) async {
        // "On Acknowledgement -> Find original Message in Sending Queue -> Remove"
        
        let repliedByIdData = Data(msg.repliedby.bytes)
        if repliedByIdData.count == 16 {
            let suffix = Array(repliedByIdData.suffix(16))
            let msgId = UUID(uuid: (suffix[0], suffix[1], suffix[2], suffix[3], suffix[4], suffix[5], suffix[6], suffix[7], suffix[8], suffix[9], suffix[10], suffix[11], suffix[12], suffix[13], suffix[14], suffix[15]))
            
            // 1. Mark as Delivered in Persistence (for ALL views)
            let sender = String(decoding: msg.from.bytes, as: UTF8.self)
            
            // We need to find the UUID of the user who sent the ACK (who is the RECIPIENT of the original message)
            // The sender name in `msg.from` is the username involved in the chat.
            let userId = await MainActor.run {
                return ChatUserStore.shared.users.first(where: { $0.name == sender })?.id
            }
            
            if let userId = userId {
                // Determine the correct user ID to store this under.
                // If I sent the original message to "Bob", Bob sends ACK.
                // The message is stored under "messages_BobID".
                // So finding Bob's ID is correct.
                ChatMessageStore.markMessageAsDelivered(userId: userId, messageId: msgId)
            }
            
            // 2. Remove from Re-send Queue
            print("[GlobalMessage] Received ACK for message \(msgId). Update UI + Remove from Send Queue.")
            await MessageSenderService.shared.processAck(for: msgId)
        }
    }
    
    // MARK: - Helper Logic
    
    private func queueAck(for originId: ASN1OctetString, sender: String, originalMsgId: UUID) async {
        guard let (myUsername, _, myPrivateKey) = certificateManager.getIdentity() else { return }
        
        // Construct ACK
        var idBytes = [UInt8](repeating: 0, count: 16)
        let _ = SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes)
        let idOctet = ASN1OctetString(contentBytes: ArraySlice(idBytes))
        
        let fromOctet = ASN1OctetString(contentBytes: ArraySlice(myUsername.utf8))
        let toOctet = ASN1OctetString(contentBytes: ArraySlice(sender.utf8))
        let emptyOctet = ASN1OctetString(contentBytes: [])
        
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
        
        guard let signature = try? myPrivateKey.signature(for: tbsData) else { return }
        let sigOctet = ASN1OctetString(contentBytes: ArraySlice(signature.rawRepresentation))
        
        let ackMsg = CHAT_Message(
            id: idOctet,
            feed_id: .p2p(CHAT_P2P(src: fromOctet, dst: toOctet)),
            signature: sigOctet,
            from: fromOctet,
            to: toOctet,
            created: ArraySlice(String(Int64(Date().timeIntervalSince1970 * 1000)).utf8),
            files: [dummyFile],
            type: CHAT_MessageType(rawValue: 4), // ACK/Read
            link: [],
            seenby: emptyOctet,
            repliedby: originId, // ID of message we are ACK-ing
            mentioned: [],
            status: CHAT_MessageStatus(rawValue: 0)
        )
        
        let protocolMsg = CHAT_CHATProtocol.message(ackMsg)
        var msgSerializer = DER.Serializer()
        try! msgSerializer.serialize(protocolMsg)
        let data = Data(msgSerializer.serializedBytes)
        
        // Add to Send Queue (via MessageSenderService)
        await MessageSenderService.shared.enqueue(data: data, type: .ack, relatedId: originalMsgId)
    }
    
    @MainActor
    private func updateUserWithMessage(
        sender: String,
        message: String,
        msgId: UUID,
        wasEncrypted: Bool,
        attachmentData: Data? = nil,
        attachmentMime: String? = nil,
        attachmentName: String? = nil
    ) {
        var user: ChatUser
        
        if let index = userStore.users.firstIndex(where: { $0.name == sender }) {
            userStore.users[index].lastMessage = message
            userStore.users[index].lastMessageDate = Date()
            userStore.users[index].unreadCount += 1
            user = userStore.users[index]
            userStore.objectWillChange.send()
        } else {
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
        
        // Save Attachment
        if let data = attachmentData, let name = attachmentName {
             Task {
                 let ext = URL(fileURLWithPath: name).pathExtension
                 if let path = try? await SecureStorageService.shared.saveEncryptedAttachment(data: data, extension: ext) {
                     await MainActor.run {
                         let updatedMsg = ChatMessage(
                             id: msgId,
                             content: message,
                             timestamp: Date(),
                             isFromMe: false,
                             senderName: sender,
                             isDelivered: true,
                             isRead: false,
                             isEncrypted: wasEncrypted,
                             attachmentData: nil,
                             attachmentMime: attachmentMime,
                             attachmentName: attachmentName,
                             localAttachmentPath: path
                         )
                         ChatMessageStore.saveMessageToChat(userId: user.id, message: updatedMsg)
                     }
                 }
             }
        }
        
        let chatMessage = ChatMessage(
            id: msgId,
            content: message,
            timestamp: Date(),
            isFromMe: false,
            senderName: sender,
            isDelivered: true,
            isRead: false,
            isEncrypted: wasEncrypted,
            attachmentData: nil,
            attachmentMime: attachmentMime,
            attachmentName: attachmentName,
            localAttachmentPath: nil
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
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
