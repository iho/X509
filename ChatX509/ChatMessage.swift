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
            startRetryLoop()
        }
    }
    
    deinit {
        retryTimer?.cancel()
        Task {
            await MulticastService.shared.stop()
        }
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
                        await multicast.send(data: safeMsg.msgDer)
                    }
                }
            }
        }
    }
    
    func sendMessage(_ content: String, attachment: Data? = nil, attachmentName: String? = nil, attachmentMime: String? = nil) {
        guard let username = certificateManager.username.data(using: .utf8),
              let privateKey = certificateManager.currentPrivateKey else {
            print("Cannot send message: Missing identity")
            return
        }
        
        // --- 1. Construct Message Components ---
        
        // ID (16 bytes random)
        var idBytes = [UInt8](repeating: 0, count: 16)
        let _ = SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes)
        let idOctet = ASN1OctetString(contentBytes: ArraySlice(idBytes))
        let msgUUID = UUID(uuid: (idBytes[0], idBytes[1], idBytes[2], idBytes[3], idBytes[4], idBytes[5], idBytes[6], idBytes[7], idBytes[8], idBytes[9], idBytes[10], idBytes[11], idBytes[12], idBytes[13], idBytes[14], idBytes[15]))
        
        // Sender & Recipient
        let fromOctet = ASN1OctetString(contentBytes: ArraySlice(username))
        let toOctet = ASN1OctetString(contentBytes: ArraySlice((recipientName.isEmpty ? "broadcast" : recipientName).utf8))
        
        // Time
        let now = Date()
        let timeInt = Int64(now.timeIntervalSince1970 * 1000)
        let createdBytes = ArraySlice(String(timeInt).utf8)
        
        // Content - Payload is either text or attachment
        let rawPayload = attachment ?? Data(content.utf8)
        let rawMime = attachmentMime ?? "text/plain"
        
        let capturedRecipientName = recipientName
        let capturedUserStore = userStore
        let capturedCmsService = cmsService
        
        // Prepare encryption on background then continue
        Task {
            var payloadData = rawPayload
            var mimeType = rawMime
            var wasEncrypted = false
            
            // Try to encrypt if we have recipient's certificate
            if !capturedRecipientName.isEmpty {
                if let certData = await MainActor.run(body: { capturedUserStore.getCertificateData(for: capturedRecipientName) }) {
                    do {
                        // Extract public key from certificate
                        let certificate = try AuthenticationFramework_Certificate(derEncoded: ArraySlice(certData))
                        let pubKeyBytes = Data(certificate.toBeSigned.subjectPublicKeyInfo.subjectPublicKey.bytes)
                        let recipientPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: pubKeyBytes)
                        
                        // Encrypt with CMS
                        payloadData = try await capturedCmsService.encrypt(data: payloadData, recipientPublicKey: recipientPublicKey)
                        mimeType = "application/cms"
                        wasEncrypted = true
                        print("Message encrypted with CMS for \(capturedRecipientName)")
                    } catch {
                        print("Encryption failed, sending plaintext: \(error)")
                    }
                }
            }
            
            // Continue on MainActor
            await self.finishSendingMessage(
                idBytes: idBytes,
                idOctet: idOctet,
                msgUUID: msgUUID,
                fromOctet: fromOctet,
                toOctet: toOctet,
                createdBytes: createdBytes,
                payloadData: payloadData,
                mimeType: mimeType,
                content: content,
                now: now,
                wasEncrypted: wasEncrypted,
                privateKey: privateKey,
                attachmentName: attachmentName,
                originalMime: rawMime, // Pass original mime (text/plain or attachment type)
                plaintextPayload: rawPayload // NEW: Pass plaintext for local UI
            )
        }
    }
    
    private func finishSendingMessage(
        idBytes: [UInt8],
        idOctet: ASN1OctetString,
        msgUUID: UUID,
        fromOctet: ASN1OctetString,
        toOctet: ASN1OctetString,
        createdBytes: ArraySlice<UInt8>,
        payloadData: Data,
        mimeType: String,
        content: String,
        now: Date,
        wasEncrypted: Bool,
        privateKey: P256.Signing.PrivateKey,
        attachmentName: String?,
        originalMime: String?,
        plaintextPayload: Data? // NEW parameter
    ) {
        // Payload: OctetString(Data) -> DER -> ASN1Any
        let payloadOctet = ASN1OctetString(contentBytes: ArraySlice(payloadData))
        var serializer = DER.Serializer()
        try! serializer.serialize(payloadOctet)
        let payloadDer = serializer.serializedBytes
        let payloadAny = try! ASN1Any(derEncoded: payloadDer)
        
        let mimeOctet = ASN1OctetString(contentBytes: ArraySlice(mimeType.utf8))
        
        // Metadata (Features) regarding file properties
        var features: [CHAT_Feature] = []
        let emptyOctet = ASN1OctetString(contentBytes: [])
        
        if let name = attachmentName {
             let key = ASN1OctetString(contentBytes: ArraySlice("filename".utf8))
             let val = ASN1OctetString(contentBytes: ArraySlice(name.utf8))
             features.append(CHAT_Feature(id: emptyOctet, key: key, value: val, group: emptyOctet))
        }
        
        if wasEncrypted, let origMime = originalMime {
             let key = ASN1OctetString(contentBytes: ArraySlice("original-mime".utf8))
             let val = ASN1OctetString(contentBytes: ArraySlice(origMime.utf8))
             features.append(CHAT_Feature(id: emptyOctet, key: key, value: val, group: emptyOctet))
        }
        
        let file = CHAT_FileDesc(
            id: idOctet,
            mime: mimeOctet,
            payload: payloadAny,
            parentid: emptyOctet,
            data: features
        )
        
        // --- 2. Sign ---
        var seqSerializer = DER.Serializer()
        try! seqSerializer.serializeSequenceOf([file])
        let filesSequenceDer = seqSerializer.serializedBytes
        var tbsData = Data(idBytes)
        tbsData.append(Data(fromOctet.bytes))
        tbsData.append(Data(toOctet.bytes))
        tbsData.append(contentsOf: filesSequenceDer)
        
        var sigOctet = ASN1OctetString(contentBytes: [])
        do {
            let signature = try privateKey.signature(for: tbsData)
            sigOctet = ASN1OctetString(contentBytes: ArraySlice(signature.rawRepresentation))
        } catch {
            print("Signing failed: \(error)")
            return
        }
        
        // --- 3. Assemble CHAT_Message ---
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
            seenby: ASN1OctetString(contentBytes: []),
            repliedby: ASN1OctetString(contentBytes: []),
            mentioned: [],
            status: CHAT_MessageStatus(rawValue: 0)
        )
        
        // --- 4. Serialize & Send ---
        let protocolMsg = CHAT_CHATProtocol.message(chatMsg)
        do {
            var msgSerializer = DER.Serializer()
            try msgSerializer.serialize(protocolMsg)
            let msgDer = msgSerializer.serializedBytes
            
            // Secure Storage: Save local copy
            Task {
                var savedPath: String?
                let dataToSave = plaintextPayload ?? payloadData
                
                if attachmentName != nil { // It's a file
                    do {
                        let ext = attachmentName.map { URL(fileURLWithPath: $0).pathExtension } ?? "dat"
                        savedPath = try await SecureStorageService.shared.saveEncryptedAttachment(data: dataToSave, extension: ext)
                    } catch {
                         print("Failed to save local attachment: \(error)")
                    }
                }
                
                await MainActor.run {
                    let uiMessage = ChatMessage(
                        id: msgUUID,
                        content: content,
                        timestamp: now,
                        isFromMe: true,
                        senderName: certificateManager.username,
                        isDelivered: false,
                        isEncrypted: wasEncrypted,
                        attachmentData: attachmentName != nil ? dataToSave : nil,
                        attachmentMime: originalMime,
                        attachmentName: attachmentName,
                        localAttachmentPath: savedPath
                    )
                    
                    self.messages.append(uiMessage)
                    self.saveMessages()
                    
                    // Add to queue
                    let safeMsg = SafeMessage(msgDer: Data(msgDer), firstAttempt: now, id: msgUUID)
                    self.outgoingQueue[msgUUID] = safeMsg
                    
                    // Initial Send
                    Task {
                        await multicast.send(data: Data(msgDer))
                    }
                }
            }
        } catch {
            print("Serialization failed: \(error)")
        }
    }
    
    private func listenForMessages() {
        Task {
            for await data in await multicast.dataStream {
                do {
                    let proto = try CHAT_CHATProtocol(derEncoded: ArraySlice(data))
                    
                    // Only process messages
                    guard case .message(let msg) = proto else { continue }
                    
                    // --- Handle ACKs (Read Receipt) ---
                    if msg.type.rawValue == 4 { // .read
                        // Ensure we have a valid ID in repliedby to know which message was read
                        let ackIdData = Data(msg.repliedby.bytes)
                        if ackIdData.count == 16 {
                            let uuid = UUID(uuid: (ackIdData[0], ackIdData[1], ackIdData[2], ackIdData[3], ackIdData[4], ackIdData[5], ackIdData[6], ackIdData[7], ackIdData[8], ackIdData[9], ackIdData[10], ackIdData[11], ackIdData[12], ackIdData[13], ackIdData[14], ackIdData[15]))
                            
                            await MainActor.run {
                                if self.outgoingQueue[uuid] != nil {
                                    print("Received ACK for \(uuid), removing from queue.")
                                    self.outgoingQueue.removeValue(forKey: uuid)
                                    self.markAsDelivered(uuid)
                                }
                            }
                        }
                        continue
                    }
                    
                    // --- Process Normal Message ---
                    
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
                    
                    // Decrypt if CMS encrypted
                    var finalMime = mimeType
                    var finalFilename: String?
                    
                    // Parse Metadata (Features)
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
                            // Convert signing key to key agreement key
                            if let signingKey = await MainActor.run(body: { certificateManager.currentPrivateKey }) {
                                // P256.Signing.PrivateKey and P256.KeyAgreement.PrivateKey share same underlying key
                                let keyData = signingKey.rawRepresentation
                                let decryptionKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: keyData)
                                payloadData = try await cmsService.decrypt(envelopedData: payloadData, privateKey: decryptionKey)
                                wasEncrypted = true
                                print("Message decrypted successfully")
                            }
                        } catch {
                            print("Decryption failed: \(error)")
                            continue // Skip message we can't decrypt
                        }
                    }
                    
                    // Fallback: If encrypted but no original-mime found (and no filename), assume text/plain
                    // This handles legacy/buggy messages that sent nil original-mime
                    if wasEncrypted && finalMime == "application/cms" && finalFilename == nil {
                        finalMime = "text/plain"
                    }
                    
                    let text: String
                    let attachmentData: Data?
                    
                    if finalMime.hasPrefix("text/") {
                         text = String(decoding: payloadData, as: UTF8.self)
                         attachmentData = nil
                    } else {
                         text = finalFilename != nil ? "Sent a file: \(finalFilename!)" : "Sent a file"
                         attachmentData = payloadData
                    }
                    
                    // Extract Sender
                    let sender = String(decoding: msg.from.bytes, as: UTF8.self)
                    
                    // Filter own messages
                    let myUsername = await MainActor.run { certificateManager.username }
                    if sender == myUsername { continue }
                    
                    // Check if message is for us (broadcast or targeted)
                    let recipient = String(decoding: msg.to.bytes, as: UTF8.self)
                    if recipient != "broadcast" && recipient != myUsername {
                        continue // Message isn't for us
                    }
                    
                    // ID
                    let idData = Data(msg.id.bytes)
                    let uuid: UUID
                    if idData.count == 16 {
                       uuid = UUID(uuid: (idData[0], idData[1], idData[2], idData[3], idData[4], idData[5], idData[6], idData[7], idData[8], idData[9], idData[10], idData[11], idData[12], idData[13], idData[14], idData[15]))
                    } else {
                        uuid = UUID()
                    }
                    
                    await MainActor.run {
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
                            attachmentMime: finalMime,
                            attachmentName: finalFilename
                        )
                        self.receiveMessage(uiMessage)
                        
                        // --- Send ACK ---
                        // Only acknowledge if it was for us
                        // We construct a simple CHAT_Message with type .read and repliedby = msg.id
                        self.sendAck(for: msg.id)
                    }
                    
                } catch {
                    // Silently ignore non-message protocol types (like presence)
                    continue
                }
            }
        }
    }
    
    private func receiveMessage(_ message: ChatMessage) {
        messages.append(message)
        saveMessages()
    }
    
    private func markAsDelivered(_ messageId: UUID) {
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].isDelivered = true
            saveMessages()
        }
    }
    
    private func saveMessages() {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: storageKey)
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
        
        // Save
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    // MARK: - ACK Sending
    private func sendAck(for originId: ASN1OctetString) {
        Task {
            guard let username = certificateManager.username.data(using: .utf8),
                  let privateKey = certificateManager.currentPrivateKey else { return }
            
            // Construct ACK Message
            // ID (random)
            var idBytes = [UInt8](repeating: 0, count: 16)
            let _ = SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes)
            let idOctet = ASN1OctetString(contentBytes: ArraySlice(idBytes))
            
            let fromOctet = ASN1OctetString(contentBytes: ArraySlice(username))
            let toOctet = ASN1OctetString(contentBytes: ArraySlice((recipientName.isEmpty ? "broadcast" : recipientName).utf8))
            
            let emptyOctet = ASN1OctetString(contentBytes: [])
            
            // Minimal file (required field)
            let dummyFile = CHAT_FileDesc(
                id: emptyOctet,
                mime: ASN1OctetString(contentBytes: ArraySlice("text/plain".utf8)),
                payload: try! ASN1Any(derEncoded: [0x05, 0x00]), // NULL
                parentid: emptyOctet,
                data: []
            )
            
            // Sign (required)
            // Just sign ID + From + To + Files
             var seqSerializer = DER.Serializer()
             try! seqSerializer.serializeSequenceOf([dummyFile])
             let filesDer = seqSerializer.serializedBytes
             var tbsData = Data(idBytes)
             tbsData.append(Data(fromOctet.bytes))
             tbsData.append(Data(toOctet.bytes))
             tbsData.append(contentsOf: filesDer)
             
            let signature = try! privateKey.signature(for: tbsData)
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
    }
}
