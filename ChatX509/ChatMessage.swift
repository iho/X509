//
//  ChatMessage.swift
//  chat509
//
//  Created on 24.12.2025.
//

import Foundation
import Combine
import SwiftASN1
import CryptoKit

/// Represents a single chat message
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let content: String
    let timestamp: Date
    let isFromMe: Bool
    let senderName: String
    var isDelivered: Bool
    var isRead: Bool
    var isEncrypted: Bool  // Track if message was encrypted
    
    // Attachment support
    var attachmentData: Data?
    var attachmentMime: String?
    var attachmentName: String?
    
    init(
        id: UUID = UUID(),
        content: String,
        timestamp: Date = Date(),
        isFromMe: Bool,
        senderName: String,
        isDelivered: Bool = false,
        isRead: Bool = false,
        isEncrypted: Bool = false,
        attachmentData: Data? = nil,
        attachmentMime: String? = nil,
        attachmentName: String? = nil,
        localAttachmentPath: String? = nil
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.senderName = senderName
        self.isDelivered = isDelivered
        self.isRead = isRead
        self.isEncrypted = isEncrypted
        self.attachmentData = attachmentData
        self.attachmentMime = attachmentMime
        self.attachmentName = attachmentName
        self.localAttachmentPath = localAttachmentPath
    }
    
    // New property for disk path
    var localAttachmentPath: String?
    
    // Custom CodingKeys to EXCLUDE binary data (`attachmentData`) from JSON preservation
    // This prevents the "Message too big" crash in UserDefaults/JSON
    enum CodingKeys: String, CodingKey {
        case id, content, timestamp, isFromMe, senderName, isDelivered, isRead, isEncrypted
        case attachmentMime, attachmentName, localAttachmentPath
        // Note: `attachmentData` is deliberately OMITTED
    }
}

@MainActor
final class ChatMessageStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    
    private let userId: UUID
    private let recipientName: String  // Name of the user we're chatting with
    private var storageKey: String { "messages_\(userId.uuidString)" }
    private let multicast = MulticastService.shared
    private let certificateManager = CertificateManager.shared
    private let userStore = ChatUserStore.shared
    private let cmsService = CMSService.shared
    
    // Reliable Delivery
    private struct SafeMessage: Sendable {
        let msgDer: Data
        let firstAttempt: Date
        let id: UUID
    }
    // Note: Dictionary access needs main actor isolation
    private var outgoingQueue: [UUID: SafeMessage] = [:]
    private var retryTimer: Task<Void, Never>?
    
    init(userId: UUID, recipientName: String = "") {
        self.userId = userId
        self.recipientName = recipientName
        loadMessages()
        
        // Start networking
        Task {
            await multicast.start()
            listenForMessages()
        }
    }
    
    deinit {
        retryTimer?.cancel()
        // Do NOT stop MulticastService here. It is a shared service used by GlobalMessageService and others.
        // Stopping it would kill the network for the whole app when a chat view is closed.
    }
    
    private func startRetryLoop() {
        retryTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000) // 5 seconds
                
                let now = Date()
                let timeout: TimeInterval = 300 // 5 minutes
                
                // Iterate queue
                for (id, safeMsg) in outgoingQueue {
                    if now.timeIntervalSince(safeMsg.firstAttempt) > timeout {
                        // Timeout
                        print("Message \(id) timed out")
                        outgoingQueue.removeValue(forKey: id)
                        // Optional: Mark as failed in UI?
                    } else {
                        // Resend
                        print("Resending message \(id)...")
                        print("Resending message \(id)...")
                        await multicast.send(data: safeMsg.msgDer, address: MulticastService.CHAT_GROUP)
                    }
                }
            }
        }
    }
    
    func sendMessage(_ content: String, attachment: Data? = nil, attachmentName: String? = nil, attachmentMime: String? = nil) {
        // Capture State on MainActor
        guard let username = certificateManager.username.data(using: .utf8),
              let privateKey = certificateManager.currentPrivateKey else {
            print("[ChatMessageStore] Cannot send message: Missing identity")
            return
        }
        
        let capturedRecipientName = recipientName
        let capturedUserStore = userStore
        let capturedCmsService = cmsService
        let capturedMulticast = multicast
        let capturedCertManager = certificateManager
        
        // Prepare initial data
        let now = Date()
        let createdBytes = ArraySlice(String(Int64(now.timeIntervalSince1970 * 1000)).utf8)
        
        // Content
        let rawPayload = attachment ?? Data(content.utf8)
        let rawMime = attachmentMime ?? "text/plain"
        
        // Capture UI updates closure
        let updateUI = { (msgUUID: UUID, wasEncrypted: Bool, savedPath: String?, msgDer: Data) in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                let uiMessage = ChatMessage(
                    id: msgUUID,
                    content: content,
                    timestamp: now,
                    isFromMe: true,
                    senderName: capturedCertManager.username,
                    isDelivered: false,
                    isEncrypted: wasEncrypted,
                    attachmentData: attachmentName != nil ? (attachment ?? Data()) : nil,
                    attachmentMime: attachmentName != nil ? rawMime : nil,
                    attachmentName: attachmentName,
                    localAttachmentPath: savedPath
                )
                
                self.messages.append(uiMessage)
                self.saveMessages()
                
                // Add to queue
                let safeMsg = SafeMessage(msgDer: msgDer, firstAttempt: now, id: msgUUID)
                self.outgoingQueue[msgUUID] = safeMsg
            }
        }

        // Offload EVERYTHING to Detached Task (CPU Bound + I/O)
        Task.detached(priority: .userInitiated) {
             print("[ChatMessageStore] Preparing to send message to '\(capturedRecipientName)'...")
             
             // 1. Encryption (CPU)
             var payloadData = rawPayload
             var mimeType = rawMime
             var wasEncrypted = false
             
             if !capturedRecipientName.isEmpty {
                 // Note: accessing userStore from background is safe if it uses internal locks or actors.
                 // ChatUserStore is MainActor, so we need to be careful.
                 // Ideally we should have captured the specific certificate data beforehand if possible.
                 // OR we call back to MainActor just for the lookup.
                 
                 let certData = await MainActor.run { capturedUserStore.getCertificateData(for: capturedRecipientName) }
                 
                 if let certData = certData {
                     do {
                         let certificate = try AuthenticationFramework_Certificate(derEncoded: ArraySlice(certData))
                         let pubKeyBytes = Data(certificate.toBeSigned.subjectPublicKeyInfo.subjectPublicKey.bytes)
                         let recipientPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: pubKeyBytes)
                         
                         payloadData = try await capturedCmsService.encrypt(data: payloadData, recipientPublicKey: recipientPublicKey)
                         mimeType = "application/cms"
                         wasEncrypted = true
                         print("Message encrypted with CMS for \(capturedRecipientName)")
                     } catch {
                         print("Encryption failed: \(error)")
                     }
                 }
             }
             
             // 2. Construction & Signing (CPU)
             // ID
             var idBytes = [UInt8](repeating: 0, count: 16)
             let _ = SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes)
             let idOctet = ASN1OctetString(contentBytes: ArraySlice(idBytes))
             let msgUUID = UUID(uuid: (idBytes[0], idBytes[1], idBytes[2], idBytes[3], idBytes[4], idBytes[5], idBytes[6], idBytes[7], idBytes[8], idBytes[9], idBytes[10], idBytes[11], idBytes[12], idBytes[13], idBytes[14], idBytes[15]))
             
             let fromOctet = ASN1OctetString(contentBytes: ArraySlice(username))
             let toOctet = ASN1OctetString(contentBytes: ArraySlice((capturedRecipientName.isEmpty ? "broadcast" : capturedRecipientName).utf8))
             
             // Payload Any
             let payloadOctet = ASN1OctetString(contentBytes: ArraySlice(payloadData))
             var serializer = DER.Serializer()
             try! serializer.serialize(payloadOctet)
             let payloadAny = try! ASN1Any(derEncoded: serializer.serializedBytes)
             
             let mimeOctet = ASN1OctetString(contentBytes: ArraySlice(mimeType.utf8))
             let emptyOctet = ASN1OctetString(contentBytes: [])
             
             // Features
             var features: [CHAT_Feature] = []
             if let name = attachmentName {
                  let key = ASN1OctetString(contentBytes: ArraySlice("filename".utf8))
                  let val = ASN1OctetString(contentBytes: ArraySlice(name.utf8))
                  features.append(CHAT_Feature(id: emptyOctet, key: key, value: val, group: emptyOctet))
             }
             if wasEncrypted {
                  let key = ASN1OctetString(contentBytes: ArraySlice("original-mime".utf8))
                  let val = ASN1OctetString(contentBytes: ArraySlice(rawMime.utf8))
                  features.append(CHAT_Feature(id: emptyOctet, key: key, value: val, group: emptyOctet))
             }
             
             let file = CHAT_FileDesc(
                 id: idOctet,
                 mime: mimeOctet,
                 payload: payloadAny,
                 parentid: emptyOctet,
                 data: features
             )
             
             // Sign
             var seqSerializer = DER.Serializer()
             try! seqSerializer.serializeSequenceOf([file])
             let filesSequenceDer = seqSerializer.serializedBytes
             var tbsData = Data(idBytes)
             tbsData.append(Data(fromOctet.bytes))
             tbsData.append(Data(toOctet.bytes))
             tbsData.append(contentsOf: filesSequenceDer)
             
             var sigOctet = ASN1OctetString(contentBytes: [])
             do {
                 let signature = try privateKey.signature(for: tbsData) // Signing is CPU heavy
                 sigOctet = ASN1OctetString(contentBytes: ArraySlice(signature.rawRepresentation))
             } catch {
                 print("Signing failed: \(error)")
                 return
             }
             
             // Assemble
             let chatMsg = CHAT_Message(
                 id: idOctet,
                 feed_id: .p2p(CHAT_P2P(src: fromOctet, dst: toOctet)),
                 signature: sigOctet,
                 from: fromOctet,
                 to: toOctet,
                 created: createdBytes,
                 files: [file],
                 type: CHAT_MessageType(rawValue: 1),
                 link: [],
                 seenby: emptyOctet,
                 repliedby: emptyOctet,
                 mentioned: [],
                 status: CHAT_MessageStatus(rawValue: 0)
             )
             
             let protocolMsg = CHAT_CHATProtocol.message(chatMsg)
             var msgSerializer = DER.Serializer()
             try! msgSerializer.serialize(protocolMsg)
             let msgDer = msgSerializer.serializedBytes
             
             // 3. Local Persistence (I/O)
             var savedPath: String?
             if attachmentName != nil {
                 do {
                     let ext = attachmentName.map { URL(fileURLWithPath: $0).pathExtension } ?? "dat"
                     // Plaintext payload for local save if available
                     savedPath = try await SecureStorageService.shared.saveEncryptedAttachment(data: rawPayload, extension: ext)
                 } catch {
                      print("Failed to save local attachment: \(error)")
                 }
             }
             
             // 4. Update UI
             updateUI(msgUUID, wasEncrypted, savedPath, Data(msgDer))
             
             // 5. Send Network (I/O)
             print("[ChatMessageStore] Sending message data (\(Data(msgDer).count) bytes) via multicast...")
             await capturedMulticast.send(data: Data(msgDer), address: MulticastService.CHAT_GROUP)
        }
    }
    
    private func listenForMessages() {
        let capturedMulticast = multicast
        let capturedRecipientName = recipientName
        let capturedCertManager = certificateManager
        let capturedCmsService = cmsService

        Task.detached(priority: .userInitiated) { [weak self] in
            print("[ChatMessageStore] Started detached listener task")
            for await data in capturedMulticast.dataStream {
                // print("[ChatMessageStore] Received packet of size \(data.count)")
                do {
                    let proto = try CHAT_CHATProtocol(derEncoded: ArraySlice(data))
                    
                    // Only process messages
                    guard case .message(let msg) = proto else { return }
                    
                    // --- Handle ACKs (Read Receipt) ---
                    if msg.type.rawValue == 4 { // .read
                        let ackIdData = Data(msg.repliedby.bytes)
                        if ackIdData.count >= 16 {
                            let suffix = Array(ackIdData.suffix(16))
                            let uuid = UUID(uuid: (suffix[0], suffix[1], suffix[2], suffix[3], suffix[4], suffix[5], suffix[6], suffix[7], suffix[8], suffix[9], suffix[10], suffix[11], suffix[12], suffix[13], suffix[14], suffix[15]))
                            
                            await MainActor.run {
                                guard let self = self else { return }
                                
                                // Always attempt to mark as delivered in the UI, even if not in local queue
                                // (e.g. if Store was recreated after sending)
                                self.markAsDelivered(uuid)
                                
                                if self.outgoingQueue[uuid] != nil {
                                    print("[ChatMessageStore] Removing ACK'd message \(uuid) from local queue.")
                                    self.outgoingQueue.removeValue(forKey: uuid)
                                }
                            }
                        }
                        continue
                    }
                    
                    // --- Process Normal Message ---
                    
                    // Extract Sender
                    let sender = String(decoding: msg.from.bytes, as: UTF8.self)
                    
                    // Get Identity (Thread Safe)
                    guard let (myUsername, _, myPrivateKey) = capturedCertManager.getIdentity() else { continue }
                    
                    // Filter own messages
                    if sender == myUsername { continue }
                    
                    // Filter Recipient
                    let recipient = String(decoding: msg.to.bytes, as: UTF8.self)
                    if recipient != "broadcast" && recipient != myUsername { continue }
                    
                    // Extract Content
                    guard let file = msg.files.first else { continue }
                    
                    // Get MIME type
                    let mimeBytes = Data(file.mime.bytes)
                    let mimeType = String(decoding: mimeBytes, as: UTF8.self)
                    
                    // Extract payload
                    var anySerializer = DER.Serializer()
                    try anySerializer.serialize(file.payload)
                    let contentOctet = try ASN1OctetString(derEncoded: anySerializer.serializedBytes)
                    var payloadData = Data(contentOctet.bytes)
                    var wasEncrypted = false
                    
                    // Decrypt if CMS encrypted (Background)
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
                    
                    if mimeType == "application/cms" {
                        do {
                            let keyData = myPrivateKey.rawRepresentation
                            let decryptionKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: keyData)
                            payloadData = try await capturedCmsService.decrypt(envelopedData: payloadData, privateKey: decryptionKey)
                            wasEncrypted = true
                        } catch {
                            print("Decryption failed: \(error)")
                            continue
                        }
                    }
                    
                    if wasEncrypted && finalMime == "application/cms" && finalFilename == nil {
                        finalMime = "text/plain"
                    }
                    
                    let text: String
                    let attachmentData: Data?
                    let isText = finalMime.hasPrefix("text/") && finalFilename == nil
                    
                    if isText {
                        text = String(decoding: payloadData, as: UTF8.self)
                        attachmentData = nil
                    } else {
                        text = finalFilename != nil ? "Sent a file: \(finalFilename!)" : "Sent a file"
                        attachmentData = payloadData
                    }
                    
                    // ID
                    let idData = Data(msg.id.bytes)
                    let uuid: UUID
                    if idData.count >= 16 {
                        let suffix = Array(idData.suffix(16))
                        uuid = UUID(uuid: (suffix[0], suffix[1], suffix[2], suffix[3], suffix[4], suffix[5], suffix[6], suffix[7], suffix[8], suffix[9], suffix[10], suffix[11], suffix[12], suffix[13], suffix[14], suffix[15]))
                    } else {
                        uuid = UUID()
                    }
                    
                    // Update UI (Main Actor)
                    await MainActor.run {
                        guard let self = self else { return }
                        let uiMessage = ChatMessage(
                            id: uuid,
                            content: text,
                            timestamp: Date(),
                            isFromMe: false,
                            senderName: sender,
                            isDelivered: true,
                            isRead: true,
                            isEncrypted: wasEncrypted,
                            attachmentData: attachmentData,
                            attachmentMime: isText ? nil : finalMime,
                            attachmentName: finalFilename
                        )
                        self.receiveMessage(uiMessage)
                    }
                    
                    // Send ACK is now handled EXCLUSIVELY by GlobalMessageService to prevent duplicate ACKs and double CPU load.
                    // await Self.sendAckInternal(...)
                    
                } catch {
                    print("[ChatMessageStore] Failed to decode packet: \(error)")
                    continue
                }
            }
        }
    }
    
    // Helper to send ACK from background without accessing MainActor state
    private static func sendAckInternal(
        originId: ASN1OctetString,
        myUsername: String,
        recipientName: String,
        privateKey: P256.Signing.PrivateKey,
        multicast: MulticastService
    ) async {
        // Construct ACK Message
        var idBytes = [UInt8](repeating: 0, count: 16)
        let _ = SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes)
        let idOctet = ASN1OctetString(contentBytes: ArraySlice(idBytes))
        
        let fromOctet = ASN1OctetString(contentBytes: ArraySlice(myUsername.utf8))
        let toOctet = ASN1OctetString(contentBytes: ArraySlice((recipientName.isEmpty ? "broadcast" : recipientName).utf8))
        let emptyOctet = ASN1OctetString(contentBytes: [])
        
        let dummyFile = CHAT_FileDesc(
            id: emptyOctet,
            mime: ASN1OctetString(contentBytes: ArraySlice("text/plain".utf8)),
            payload: try! ASN1Any(derEncoded: [0x05, 0x00]), // NULL
            parentid: emptyOctet,
            data: []
        )
        
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
            repliedby: originId,
            mentioned: [],
            status: CHAT_MessageStatus(rawValue: 0)
        )
        
        let protocolMsg = CHAT_CHATProtocol.message(ackMsg)
        var msgSerializer = DER.Serializer()
        try! msgSerializer.serialize(protocolMsg)
        
        await multicast.send(data: Data(msgSerializer.serializedBytes), address: MulticastService.CHAT_GROUP)
    }

    private func receiveMessage(_ message: ChatMessage) {
        // Deduplication: Check if message with this ID already exists
        if messages.contains(where: { $0.id == message.id }) {
            print("[ChatMessageStore] Duplicate message \(message.id) received. Ignoring content but will send ACK.")
            return
        }
        messages.append(message)
        saveMessages()
    }
    
    private func markAsDelivered(_ messageId: UUID) {
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            // Deduplication: Don't update or log if already marked
            if messages[index].isDelivered { return }
            
            print("[ChatMessageStore] Marking message \(messageId) as DELIVERED in UI model.")
            messages[index].isDelivered = true
            saveMessages()
        } else {
            print("[ChatMessageStore] Failed to find message \(messageId) to mark as delivered.")
        }
    }
    
    static let persistenceQueue = DispatchQueue(label: "com.chatx509.messagestore.persistence", qos: .background)

    private func saveMessages() {
        let snapshot = self.messages
        let key = self.storageKey
        
        Self.persistenceQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
    
    private func loadMessages() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return
        }
        messages = decoded
    }
    
    // MARK: - Static Message Storage (for GlobalMessageService)
    
    /// Save a message to a user's chat storage (called from GlobalMessageService)
    static func saveMessageToChat(userId: UUID, message: ChatMessage) {
        let storageKey = "messages_\(userId.uuidString)"
        var messages: [ChatMessage] = []
        
        // Load existing
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = decoded
        }
        
        // Append new message if not duplicate
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
        }
        
        // Save using the shared static queue to prevent races and Main Thread blocks
        persistenceQueue.async {
            // Re-load latest to ensure we append to most recent state (in case Instance wrote recently)
            var currentMessages: [ChatMessage] = []
            if let data = UserDefaults.standard.data(forKey: storageKey),
               let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                 currentMessages = decoded
            }
            
            // Check duplicate again in case it was added while waiting in queue
            if !currentMessages.contains(where: { $0.id == message.id }) {
                currentMessages.append(message)
                
                if let data = try? JSONEncoder().encode(currentMessages) {
                    UserDefaults.standard.set(data, forKey: storageKey)
                }
            }
        }
    }
    
    /// Mark a message as delivered in the static storage (called from GlobalMessageService)
    static func markMessageAsDelivered(userId: UUID, messageId: UUID) {
        let storageKey = "messages_\(userId.uuidString)"
        
        persistenceQueue.async {
            // Load
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  var messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
                return
            }
            
            // Find & Update
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                // Deduplication check
                if messages[index].isDelivered { return }
                
                messages[index].isDelivered = true
                
                // Save
                if let encoded = try? JSONEncoder().encode(messages) {
                    UserDefaults.standard.set(encoded, forKey: storageKey)
                    print("[ChatMessageStore] (Static) Marked message \(messageId) as DELIVERED for user \(userId)")
                }
            }
        }
    }
}
