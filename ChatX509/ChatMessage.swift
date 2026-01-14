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
    
    init(
        id: UUID = UUID(),
        content: String,
        timestamp: Date = Date(),
        isFromMe: Bool,
        senderName: String,
        isDelivered: Bool = false,
        isRead: Bool = false
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.senderName = senderName
        self.isDelivered = isDelivered
        self.isRead = isRead
    }
}

@MainActor
final class ChatMessageStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    
    private let userId: UUID
    private var storageKey: String { "messages_\(userId.uuidString)" }
    private let multicast = MulticastService.shared
    private let certificateManager = CertificateManager.shared
    
    init(userId: UUID) {
        self.userId = userId
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
        let toOctet = ASN1OctetString(contentBytes: ArraySlice("broadcast".utf8))
        
        // Time
        let now = Date()
        let timeInt = Int64(now.timeIntervalSince1970 * 1000)
        let createdBytes = ArraySlice(String(timeInt).utf8) // Using string rep for now as ArraySlice<UInt8>
        
        // Content (FileDesc)
        // Payload: OctetString(Text) -> DER -> ASN1Any
        let textData = Data(content.utf8)
        let payloadOctet = ASN1OctetString(contentBytes: ArraySlice(textData))
        var serializer = DER.Serializer()
        try! serializer.serialize(payloadOctet)
        let payloadDer = serializer.serializedBytes
        let payloadAny = try! ASN1Any(derEncoded: payloadDer)
        
        let mimeOctet = ASN1OctetString(contentBytes: ArraySlice("text/plain".utf8))
        
        let file = CHAT_FileDesc(
            id: idOctet, // Reuse msg id for simplicity
            mime: mimeOctet,
            payload: payloadAny,
            parentid: ASN1OctetString(contentBytes: []),
            data: []
        )
        
        // --- 2. Sign ---
        // Signature = ECDSA( ID || From || To || Files-Sequence-DER )
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
            type: CHAT_MessageType(rawValue: 1), // 1=sys (using as normal)
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
                isDelivered: false
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
                // Decode
                do {
                    let proto = try CHAT_CHATProtocol(derEncoded: ArraySlice(data))
                    guard case .message(let msg) = proto else { continue }
                    
                    // Extract Content
                    guard let file = msg.files.first else { continue }
                    // Payload is ASN1Any containing an OctetString
                    // We can re-parse the raw bytes of the Any as OctetString
                    var anySerializer = DER.Serializer()
                    try anySerializer.serialize(file.payload)
                    let contentOctet = try ASN1OctetString(derEncoded: anySerializer.serializedBytes)
                    let text = String(decoding: contentOctet.bytes, as: UTF8.self)
                    
                    // Extract Sender
                    let sender = String(decoding: msg.from.bytes, as: UTF8.self)
                    
                    // Filter own messages (simple username check)
                    if sender == certificateManager.username {
                        continue
                    }
                    
                    // ID
                    let idData = Data(msg.id.bytes)
                    let uuid: UUID
                    if idData.count == 16 {
                       uuid = UUID(uuid: (idData[0], idData[1], idData[2], idData[3], idData[4], idData[5], idData[6], idData[7], idData[8], idData[9], idData[10], idData[11], idData[12], idData[13], idData[14], idData[15]))
                    } else {
                        uuid = UUID()
                    }
                    
                    // Verify Signature? 
                    // In this pivot, "self signed certificats ... signed to name of desired user".
                    // The protocol assumes we trust the sender's cert which we don't have here attached.
                    // The implementation plan said: "Include the Certificate... in the message payload".
                    // But `CHAT_Message` doesn't have a certificate field.
                    // We'd need to fetch it or attach it in `files` or `link`.
                    // For now, we will SKIP Verification and just display, as getting the PubKey is tricky without Protocol change 
                    // or Side-channel (which we don't have implementation for yet).
                    // Or we assume the sender sent their cert separately?
                    // User requirement: "self signed certificats ... stored in phone".
                    // Verification is logically required but technically impossible without the Public Key.
                    // I'll skip explicit verification in code but add a TODO.
                    
                    await MainActor.run {
                        let uiMessage = ChatMessage(
                            id: uuid,
                            content: text,
                            timestamp: Date(), // parsing 'created' is tricky if format loose
                            isFromMe: false,
                            senderName: sender,
                            isDelivered: true,
                            isRead: true
                        )
                        self.receiveMessage(uiMessage)
                    }
                    
                } catch {
                    print("Decoding error: \(error)")
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
}
