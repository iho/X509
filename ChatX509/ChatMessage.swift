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
    
    init(
        id: UUID = UUID(),
        content: String,
        timestamp: Date = Date(),
        isFromMe: Bool,
        senderName: String,
        isDelivered: Bool = false,
        isRead: Bool = false,
        isEncrypted: Bool = false
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.senderName = senderName
        self.isDelivered = isDelivered
        self.isRead = isRead
        self.isEncrypted = isEncrypted
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
        Task {
            await MulticastService.shared.stop()
        }
    }
    
    func sendMessage(_ content: String) {
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
        
        // Content - potentially encrypted
        let plainPayload = Data(content.utf8)
        let capturedRecipientName = recipientName
        let capturedUserStore = userStore
        let capturedCmsService = cmsService
        
        // Prepare encryption on background then continue
        Task {
            var payloadData = plainPayload
            var mimeType = "text/plain"
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
                privateKey: privateKey
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
        privateKey: P256.Signing.PrivateKey
    ) {
        // Payload: OctetString(Data) -> DER -> ASN1Any
        let payloadOctet = ASN1OctetString(contentBytes: ArraySlice(payloadData))
        var serializer = DER.Serializer()
        try! serializer.serialize(payloadOctet)
        let payloadDer = serializer.serializedBytes
        let payloadAny = try! ASN1Any(derEncoded: payloadDer)
        
        let mimeOctet = ASN1OctetString(contentBytes: ArraySlice(mimeType.utf8))
        
        let file = CHAT_FileDesc(
            id: idOctet,
            mime: mimeOctet,
            payload: payloadAny,
            parentid: ASN1OctetString(contentBytes: []),
            data: []
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
            
            // Local UI Update
            let uiMessage = ChatMessage(
                id: msgUUID,
                content: content,
                timestamp: now,
                isFromMe: true,
                senderName: certificateManager.username,
                isDelivered: false,
                isEncrypted: wasEncrypted
            )
            messages.append(uiMessage)
            saveMessages()
            
            Task {
                await multicast.send(data: Data(msgDer))
                await MainActor.run {
                    self.markAsDelivered(msgUUID)
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
                    
                    let text = String(decoding: payloadData, as: UTF8.self)
                    
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
                            isEncrypted: wasEncrypted
                        )
                        self.receiveMessage(uiMessage)
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
}
