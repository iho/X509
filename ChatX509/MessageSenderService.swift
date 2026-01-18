//
//  MessageSenderService.swift
//  ChatX509
//
//  Created on 15.01.2026.
//

import Foundation
import Network

/// Handles reliable message delivery (Send Looper from Protocol v1)
/// "For each message/acknowledgement... send 5 identical copies every 10 seconds"
final class MessageSenderService: @unchecked Sendable {
    static let shared = MessageSenderService()
    
    // Config
    private let burstCount = 5
    private let loopInterval: TimeInterval = 10.0
    private let burstSpacing: UInt64 = 100_000_000 // 100ms spacing between burst packets
    private let maxRetries = 6 * 10 // ~10 minutes?
    // Spec says: "removed... if recipient is offline for too long".
    
    // State
    private let serviceLock = NSLock()
    private var isRunning = false
    private var maintenanceTask: Task<Void, Never>?
    
    enum MessageType {
        case message
        case ack
    }
    
    struct QueueItem: Identifiable {
        let id = UUID()
        let data: Data
        let type: MessageType
        let relatedId: UUID // The ID of the message being sent or ACKed (to allow removal)
        var createdAt: Date
        var lastSent: Date?
        var retryCount: Int
    }
    
    private var outgoingQueue: [QueueItem] = []
    
    private let multicast = MulticastService.shared
    
    private init() {
         start()
    }
    
    func start() {
        serviceLock.lock()
        if isRunning { 
            serviceLock.unlock()
            return
        }
        isRunning = true
        serviceLock.unlock()
        
        maintenanceTask = Task.detached { [weak self] in
            await self?.runSendLoop()
        }
        
        print("[MessageSender] Started Send Looper")
    }
    
    func stop() {
        serviceLock.lock()
        isRunning = false
        serviceLock.unlock()
        
        maintenanceTask?.cancel()
    }
    
    func restart() async {
        stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        start()
    }
    
    /// Enqueue a message for reliable sending
    /// - Parameters:
    ///   - data: The DER encoded CHATProtocol message
    ///   - type: .message or .ack
    ///   - relatedId: The internal UUID of the message (from CHAT_Message.id). Used for ACK matching.
    func enqueue(data: Data, type: MessageType, relatedId: UUID) async {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        
        // Check if already exists (deduplicate)
        if outgoingQueue.contains(where: { $0.relatedId == relatedId && $0.type == type }) {
            print("[MessageSender] Ignoring duplicate enqueue request for \(relatedId)")
            return
        }
        
        // Add to queue
        let item = QueueItem(data: data, type: type, relatedId: relatedId, createdAt: Date(), lastSent: nil, retryCount: 0)
        outgoingQueue.append(item)
        
        print("[MessageSender] Enqueued \(type) for \(relatedId). Queue Size: \(outgoingQueue.count)")
        
        // Trigger immediate send?
        // Spec says "Send Looper... sends 5 identical copies every 10 seconds".
        // We can trigger one pass immediately.
    }
    
    /// Called when an ACK is received for a message ID
    func processAck(for messageId: UUID) async {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        
        if let index = outgoingQueue.firstIndex(where: { $0.relatedId == messageId && $0.type == .message }) {
            outgoingQueue.remove(at: index)
            print("[MessageSender] Removed message \(messageId) from queue (ACK received)")
        }
    }
    
    private func runSendLoop() async {
        while true {
            serviceLock.lock()
            let running = isRunning
            serviceLock.unlock()
            
            if !running { break }
            
            // Process Queue
            await processQueue()
            
            // Wait 10 seconds
            try? await Task.sleep(nanoseconds: UInt64(loopInterval * 1_000_000_000))
        }
    }
    
    private func processQueue() async {
        // Copy queue to iterate safely
        serviceLock.lock()
        let items = outgoingQueue
        serviceLock.unlock()
        
        if items.isEmpty { return }
        
        // print("[MessageSender] Processing Queue: \(items.count) items")
        
        for item in items {
             // Burst Send (5 copies)
             await sendBurst(item: item)
             
             // Update stats or remove if expired
             serviceLock.lock()
             if let idx = outgoingQueue.firstIndex(where: { $0.id == item.id }) {
                 outgoingQueue[idx].lastSent = Date()
                 outgoingQueue[idx].retryCount += 1
                 
                 // Expire?
                 // ACKs stop after 1 minute (6 retries * 10s)
                 // Messages stop after maxRetries (10 minutes)
                 let limit = item.type == .ack ? 6 : maxRetries
                 
                 if outgoingQueue[idx].retryCount >= limit {
                     outgoingQueue.remove(at: idx)
                     let typeStr = item.type == .ack ? "ACK" : "Message"
                     print("[MessageSender] \(typeStr) for \(item.relatedId) expired after \(limit) attempts")
                 }
             }
             serviceLock.unlock()
        }
    }
    
    private func sendBurst(item: QueueItem) async {
        // Send 5 copies
        // print("[MessageSender] Sending burst for \(item.relatedId)")
        
        for i in 0..<burstCount {
            multicast.send(data: item.data)
            
            if i < burstCount - 1 {
                try? await Task.sleep(nanoseconds: burstSpacing)
            }
        }
    }
}
