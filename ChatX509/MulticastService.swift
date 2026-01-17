//
//  MulticastService.swift
//  chat509
//
//  Created on 14.01.2026.
//

import Foundation
import Network

/// Handles UDP Multicast networking for the chat application
actor MulticastService {
    static let shared = MulticastService()
    
    // MARK: - Debug Stats
    struct DebugStats {
        let isRunning: Bool
        let receiveSocketFD: Int32
        let sendSocketFD: Int32
        let interfaceAddress: String
        let totalBytesSent: Int
        let totalBytesReceived: Int
        let pendingMessagesCount: Int
        let sentMessagesCacheCount: Int
        let activeListeners: Int
        let processedTransactionsCount: Int
    }
    
    private var totalBytesSent = 0
    private var totalBytesReceived = 0
    
    func getDebugStats() -> DebugStats {
        return DebugStats(
            isRunning: isRunning,
            receiveSocketFD: receiveSocketFD,
            sendSocketFD: sendSocketFD,
            interfaceAddress: getInterfaceAddress() ?? "Unknown",
            totalBytesSent: totalBytesSent,
            totalBytesReceived: totalBytesReceived,
            pendingMessagesCount: pendingMessages.count,
            sentMessagesCacheCount: sentMessagesCache.count,
            activeListeners: continuations.count,
            processedTransactionsCount: processedTransactions.count
        )
    }
    
    // Configuration
    static let BROADCAST_GROUP = "239.1.42.1"     // For Discovery
    static let CHAT_GROUP = "239.1.42.28"         // For Chat & Files
    /*
    private let multicastGroupAddress = "255.255.255.255" // Deprecated
    */
    private let port: UInt16 = 55555
    private let bufferSize = 65536
    

    
    // State
    private var isRunning = false
    private var receiveSocketFD: Int32 = -1
    private var sendSocketFD: Int32 = -1
    
    // Support multiple stream consumers
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    
    /// Returns a new stream for receiving data. Each caller gets their own stream.
    var dataStream: AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            Task {
                await self?.addContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task {
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }
    
    private func addContinuation(id: UUID, continuation: AsyncStream<Data>.Continuation) {
        continuations[id] = continuation
    }
    
    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
    
    private init() {}
    
    func start() {
        guard !isRunning else { return }
        
        setupSocket()
        if receiveSocketFD >= 0 && sendSocketFD >= 0 {
            isRunning = true
            startListening()
            startMaintenanceLoop()
            print("MulticastService started. Listening on \(MulticastService.BROADCAST_GROUP) and \(MulticastService.CHAT_GROUP). Port: \(port)")
            
            startNetworkMonitoring()
        }
    }
    
    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor?.cancel()
        monitor = nil
        maintenanceTask?.cancel() // Cancel maintenance task
        
        if receiveSocketFD >= 0 {
            close(receiveSocketFD)
            receiveSocketFD = -1
        }
        if sendSocketFD >= 0 {
            close(sendSocketFD)
            sendSocketFD = -1
        }
    }

    // ... (Network Monitoring code remains here, skipped for replacement) ...

    private func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task.detached { [weak self] in
            while await self?.getIsRunning() == true {
                 try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s check
                 if Task.isCancelled { break }
                 await self?.performMaintenance()
            }
        }
    }
    
    // MARK: - Network Monitoring
    private var monitor: NWPathMonitor?
    private var lastInterface: String?
    
    private func startNetworkMonitoring() {
        monitor?.cancel()
        
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handleNetworkChange(path: path)
            }
        }
        
        let queue = DispatchQueue(label: "NetworkMonitor")
        pathMonitor.start(queue: queue)
        monitor = pathMonitor
    }
    
    private func handleNetworkChange(path: NWPath) {
        // Log status
        // print("[MulticastService] Network Path Update: \(path.status)")
        
        guard path.status == .satisfied else {
            // print("[MulticastService] Network unsatisfied. Waiting...")
            return
        }
        
        // Check if interface IP changed
        guard let currentIP = getInterfaceAddress() else { return }
        
        if let last = lastInterface, last != currentIP {
            print("[MulticastService] Network change detected (\(last) -> \(currentIP)). Restarting service...")
            restart()
        }
        
        lastInterface = currentIP
    }
    
    private func restart() {
        print("[MulticastService] Restarting sockets...")
        stop()
        
        // Brief pause to allow sockets to close
        sleep(1) // 1s
        
        start()
        
        // Announce immediately after restart
        Task {
            await UserDiscoveryService.shared.announceNow()
        }
    }
    
    // MARK: - Chunking State
    
    // MARK: - Reliable UDP Logic (NACK)
    
    private struct ChunkHeader {
        let transactionId: UUID
        let sequenceNumber: UInt16
        let totalChunks: UInt16
        let type: UInt8 // 0 = Data, 1 = NACK
        
        static let size = 16 + 2 + 2 + 1 // 21 bytes
        
        init(transactionId: UUID, sequenceNumber: UInt16, totalChunks: UInt16, type: UInt8 = 0) {
            self.transactionId = transactionId
            self.sequenceNumber = sequenceNumber
            self.totalChunks = totalChunks
            self.type = type
        }
        
        init?(data: Data) {
            guard data.count >= ChunkHeader.size else { return nil }
            
            let uuidData = data.prefix(16)
            self.transactionId = UUID(uuid: (uuidData[0], uuidData[1], uuidData[2], uuidData[3], uuidData[4], uuidData[5], uuidData[6], uuidData[7], uuidData[8], uuidData[9], uuidData[10], uuidData[11], uuidData[12], uuidData[13], uuidData[14], uuidData[15]))
            
            let seqData = data.dropFirst(16).prefix(2)
            self.sequenceNumber = seqData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            
            let totalData = data.dropFirst(18).prefix(2)
            self.totalChunks = totalData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            
            self.type = data[20]
        }
        
        var encoded: Data {
            var data = Data()
            withUnsafeBytes(of: transactionId.uuid) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: sequenceNumber.bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: totalChunks.bigEndian) { data.append(contentsOf: $0) }
            data.append(type)
            return data
        }
    }
    
    // Cache of sent messages for retransmission
    private struct SentMessage {
        let chunks: [Data]
        let timestamp: Date
    }
    private var sentMessagesCache: [UUID: SentMessage] = [:]
    
    private struct PendingMessage {
        var chunks: [UInt16: Data]
        var totalChunks: UInt16
        var lastUpdate: Date
    }
    
    private var pendingMessages: [UUID: PendingMessage] = [:]
    private var processedTransactions: Set<UUID> = []
    
    // Check pending messages frequently for NACKs (e.g., every 500ms)
    private var maintenanceTask: Task<Void, Never>?
    
    private let cleanupInterval: TimeInterval = 30
    private var lastCleanupTime = Date()
    private let maxChunkSize = 1024 // Reduced from 1400 to avoid MTU issues
    
    // ... existing start/stop ...
    
    func send(data: Data, address: String) {
        guard isRunning, sendSocketFD >= 0 else { return }
        
        let totalLen = data.count
        let chunkCount = Int(ceil(Double(totalLen) / Double(maxChunkSize)))
        
        guard chunkCount <= UInt16.max else {
            print("Error: Data too large to send (\(totalLen) bytes)")
            return
        }
        
        let transactionId = UUID()
        let totalChunks = UInt16(chunkCount)
        
        print("[MulticastService] Sending \(totalLen) bytes (ID: \(transactionId), Chunks: \(totalChunks))")
        
        var allChunks: [Data] = []
        
        for i in 0..<chunkCount {
            let start = i * maxChunkSize
            let end = min(start + maxChunkSize, totalLen)
            let chunkPayload = data.subdata(in: start..<end)
            
            let header = ChunkHeader(transactionId: transactionId, sequenceNumber: UInt16(i), totalChunks: totalChunks, type: 0)
            var packet = header.encoded
            packet.append(chunkPayload)
            
            allChunks.append(packet)
            
            
            sendPacket(packet, address: address)
            
            // Pacing
            if i % 10 == 0 { usleep(1000) }
            usleep(2000) // 2ms pacing
        }
        
        // Cache for retransmission
        if chunkCount > 1 {
            sentMessagesCache[transactionId] = SentMessage(chunks: allChunks, timestamp: Date())
        }
    }
    
    // Send a NACK packet requesting missing chunks
    private func sendNack(transactionId: UUID, missingIndices: [UInt16]) {
        // NACK Format: Header (Type=1) + List of UInt16 indices
        let header = ChunkHeader(transactionId: transactionId, sequenceNumber: 0, totalChunks: 0, type: 1)
        var packet = header.encoded
        
        // Limit NACK size
        let maxIndices = (maxChunkSize - ChunkHeader.size) / 2
        let indicesToSend = missingIndices.prefix(maxIndices)
        
        for index in indicesToSend {
            withUnsafeBytes(of: index.bigEndian) { packet.append(contentsOf: $0) }
        }
        
        print("[MulticastService] Sending NACK for ID \(transactionId) requesting \(indicesToSend.count) chunks")
        sendPacket(packet, address: MulticastService.CHAT_GROUP)
    }
    
    private func sendPacket(_ data: Data, address: String) {
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &dst.sin_addr)
        dst.sin_zero = (0, 0, 0, 0, 0, 0, 0, 0)
        
        let dstLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let sent = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &dst) { dstPtr in
                dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reb in
                    sendto(sendSocketFD, ptr.baseAddress, data.count, 0, reb, dstLen)
                }
            }
        }
        
        if sent < 0 {
            print("Send failed: \(String(cString: strerror(errno)))")
        } else {
            totalBytesSent += sent
            // print("Sent packet \(sent) bytes")
        }
    }
    
    // MARK: - Private Setup
    
    private func setupSocket() {
        // --- 1. Receive Socket Setup ---
        receiveSocketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard receiveSocketFD >= 0 else {
            print("Failed to create receive socket: \(String(cString: strerror(errno)))")
            return
        }
        
        var reuse: Int32 = 1
        setsockopt(receiveSocketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(receiveSocketFD, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        // Bind to multicast address
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // Bind to INADDR_ANY to receive Broadcast/Multicast from all interfaces
        addr.sin_addr.s_addr = 0 // INADDR_ANY
        
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reb in
                bind(receiveSocketFD, reb, addrLen)
            }
        }
        
        guard bindResult == 0 else {
            print("Bind failed: \(String(cString: strerror(errno)))")
            close(receiveSocketFD)
            receiveSocketFD = -1
            return
        }
        
        // Join Multicast Groups
        joinMulticastGroup(address: MulticastService.BROADCAST_GROUP)
        joinMulticastGroup(address: MulticastService.CHAT_GROUP)
        
        // --- 2. Send Socket Setup ---
        sendSocketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sendSocketFD >= 0 else {
            print("Failed to create send socket: \(String(cString: strerror(errno)))")
            return
        }
        
        // Standard options for send socket
        setsockopt(sendSocketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sendSocketFD, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sendSocketFD, SOL_SOCKET, SO_BROADCAST, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        // Configure TX (Interface, TTL, Loop)
        configureSendSocket()
        
        print("Multicast socket setup complete (RX: \(receiveSocketFD), TX: \(sendSocketFD)).")
    }
    
    private func joinMulticastGroup(address: String) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            guard let firstAddr = ifaddr else { return }
            
            for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                let addr = ptr.pointee.ifa_addr.pointee
                
                if addr.sa_family == UInt8(AF_INET) &&
                   (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING) {
                    
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        let ifName = String(cString: ptr.pointee.ifa_name)
                        print("Joining multicast group \(address) on \(ifName) (\(ip))")
                        
                        var mreq = ip_mreq()
                        inet_pton(AF_INET, address, &mreq.imr_multiaddr)
                        inet_pton(AF_INET, ip, &mreq.imr_interface)
                        
                        let result = setsockopt(receiveSocketFD, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
                        if result != 0 {
                             print("Failed to join group on \(ifName): \(String(cString: strerror(errno)))")
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
    }
    
    private func configureSendSocket() {
        // 1. Set Outgoing Interface (IP_MULTICAST_IF)
        if let interfaceIP = getInterfaceAddress() {
            var interfaceAddr = in_addr()
            inet_pton(AF_INET, interfaceIP, &interfaceAddr)
            let ifSetResult = setsockopt(sendSocketFD, IPPROTO_IP, IP_MULTICAST_IF, &interfaceAddr, socklen_t(MemoryLayout<in_addr>.size))
            if ifSetResult != 0 {
                 print("Failed to set outgoing multicast interface: \(String(cString: strerror(errno)))")
            } else {
                 print("Set outgoing multicast interface to: \(interfaceIP)")
            }
        } else {
            print("No active interface found for setting outbound multicast")
        }
        
        // 2. Set TTL to 255
        var ttl: UInt8 = 255
        let ttlResult = setsockopt(sendSocketFD, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        if ttlResult != 0 {
            print("Failed to set TTL: \(String(cString: strerror(errno)))")
        }
        
        // 3. Enable Loopback
        var loop: UInt8 = 1
        setsockopt(sendSocketFD, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
    }
    
    // Helper to find the best active interface IP (preferring en0/Wi-Fi)
    private func getInterfaceAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            let name = String(cString: ptr.pointee.ifa_name)
            
            // Skip cellular interfaces
            if name.hasPrefix("pdp_ip") { continue }
            
            // Check for running IPv4 interface that is not loopback
            if (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if (getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, 0, NI_NUMERICHOST) == 0) {
                        let ipAsString = String(cString: hostname)
                        
                        // Pick the first valid one, but prefer en0 (Wi-Fi)
                        if address == nil || name == "en0" {
                             address = ipAsString
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
    
    private func startListening() {
        Task.detached {
            guard let fd = await self.getReceiveSocketFD() else { return }
            // Increase recv buffer to handle larger packets or multiple chunks
            var buffer = [UInt8](repeating: 0, count: 65536)
            
            while await self.getIsRunning() {
                var sender = sockaddr_storage()
                var senderLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                
                let bytesRead = withUnsafeMutablePointer(to: &sender) { senderPtr in
                    senderPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebPtr in
                        recvfrom(fd, &buffer, buffer.count, 0, rebPtr, &senderLen)
                    }
                }
                
                if bytesRead > 0 {
                    let receivedData = Data(buffer[0..<bytesRead])
                    
                    // Debug Log: Print sender IP
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    withUnsafePointer(to: &sender) { senderPtr in
                        senderPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                            if getnameinfo(saPtr, senderLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                                let senderIP = String(cString: hostname)
                                print("RX \(bytesRead) bytes from \(senderIP)")
                            }
                        }
                    }
                    
                    await self.incrementStats(rx: bytesRead)
                    await self.processReceivedPacket(receivedData)
                } else {
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            }
        }
    }
    
    private func incrementStats(rx: Int) {
        totalBytesReceived += rx
    }
    

    
    private func performMaintenance() {
         let now = Date()
         
         // 1. Cleanup old sent cache
         let oldCache = sentMessagesCache.filter { now.timeIntervalSince($0.value.timestamp) > 60 } // Keep for 60s
         for (id, _) in oldCache { sentMessagesCache.removeValue(forKey: id) }
         
         // 2. Cleanup old pending messages
         let expired = pendingMessages.filter { now.timeIntervalSince($0.value.lastUpdate) > 60 }
         for (id, _) in expired { pendingMessages.removeValue(forKey: id) }
         
         // 3. Clear processed cache periodically
         if processedTransactions.count > 1000 {
             processedTransactions.removeAll()
         }
         
         // 4. Check for stalled pending messages (NACK Trigger)
        for (id, pending) in pendingMessages {
            // If incomplete and stalled for > 1.0s
            if pending.chunks.count < pending.totalChunks && now.timeIntervalSince(pending.lastUpdate) > 1.0 {
                // Identify missing chunks
                 var missing: [UInt16] = []
                 for i in 0..<pending.totalChunks {
                     if pending.chunks[i] == nil {
                         missing.append(i)
                     }
                 }
                 
                 if !missing.isEmpty {
                     sendNack(transactionId: id, missingIndices: missing)
                     // Update lastUpdate so we don't spam NACKs immediately
                     pendingMessages[id]?.lastUpdate = Date()
                 }
             }
         }
    }
    
    private func processReceivedPacket(_ data: Data) {
        guard let header = ChunkHeader(data: data) else {
            print("[MulticastService] Failed to parse ChunkHeader from \(data.count) bytes")
            return
        }
        
        // Handle NACK
        if header.type == 1 {
            // NACK Packet
            handleNack(header: header, data: data)
            return
        }
        
        // Handle Data
        if processedTransactions.contains(header.transactionId) {
            // print("[MulticastService] Ignoring duplicate transaction \(header.transactionId)")
            return
        }
        
        let payload = data.dropFirst(ChunkHeader.size)
        // print("[MulticastService] Processing packet ID: \(header.transactionId), Seq: \(header.sequenceNumber)/\(header.totalChunks), Type: \(header.type)")
        
        if header.totalChunks == 1 {
            processedTransactions.insert(header.transactionId)
            print("[MulticastService] Single chunk message complete. Publishing \(payload.count) bytes to \(continuations.count) listeners.")
            publishData(payload)
            return
        }
        
        if pendingMessages[header.transactionId] == nil {
             pendingMessages[header.transactionId] = PendingMessage(chunks: [:], totalChunks: header.totalChunks, lastUpdate: Date())
        }
        
        pendingMessages[header.transactionId]?.chunks[header.sequenceNumber] = payload
        pendingMessages[header.transactionId]?.lastUpdate = Date()
        
        // Check Completion
        if let pending = pendingMessages[header.transactionId], pending.chunks.count == pending.totalChunks {
            var fullData = Data()
            for i in 0..<pending.totalChunks {
                if let part = pending.chunks[i] {
                    fullData.append(part)
                }
            }
            
            processedTransactions.insert(header.transactionId)
            publishData(fullData)
            pendingMessages.removeValue(forKey: header.transactionId)
        }
    }
    
    private func handleNack(header: ChunkHeader, data: Data) {
        // NACK payload is list of UInt16
        let nackPayload = data.dropFirst(ChunkHeader.size)
        // Check if we have this message in sent cache
        guard let sentMsg = sentMessagesCache[header.transactionId] else {
             // We don't have it anymore, or never sent it. Ignore.
             return
        }
        
        print("[MulticastService] Received NACK for ID \(header.transactionId). Resending chunks...")
        
        let count = nackPayload.count / 2
        for i in 0..<count {
             let startIndex = i * 2
             let indexData = nackPayload.subdata(in: startIndex..<(startIndex + 2))
             let chunkIndex = indexData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
             
             if Int(chunkIndex) < sentMsg.chunks.count {
                 let packet = sentMsg.chunks[Int(chunkIndex)]
                 sendPacket(packet, address: MulticastService.CHAT_GROUP)
                 usleep(2000) // Pace retransmissions too
             }
        }
    }
    
    // ... Helpers ...
    private func publishData(_ data: Data) {
        for (_, continuation) in continuations {
            continuation.yield(data)
        }
    }
    
    // Helpers for detached task access
    private func getReceiveSocketFD() -> Int32? {
        return receiveSocketFD >= 0 ? receiveSocketFD : nil
    }
    
    private func getIsRunning() -> Bool {
        return isRunning
    }
}
