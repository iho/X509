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
    
    // Configuration
    private let multicastGroupAddress = "239.1.42.99"
    private let port: UInt16 = 55555
    private let bufferSize = 65536
    
    // State
    private var isRunning = false
    private var socketFD: Int32 = -1
    
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
        if socketFD >= 0 {
            isRunning = true
            startListening()
            print("MulticastService started on \(multicastGroupAddress):\(port)")
        }
    }
    
    func stop() {
        guard isRunning else { return }
        isRunning = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }
    
    // MARK: - Chunking State
    
    private struct ChunkHeader {
        let transactionId: UUID
        let sequenceNumber: UInt16
        let totalChunks: UInt16
        
        static let size = 16 + 2 + 2 // 20 bytes
        
        // Memberwise initializer
        init(transactionId: UUID, sequenceNumber: UInt16, totalChunks: UInt16) {
            self.transactionId = transactionId
            self.sequenceNumber = sequenceNumber
            self.totalChunks = totalChunks
        }
        
        // Data decoding initializer
        init?(data: Data) {
            guard data.count >= ChunkHeader.size else { return nil }
            
            let uuidData = data.prefix(16)
            self.transactionId = UUID(uuid: (uuidData[0], uuidData[1], uuidData[2], uuidData[3], uuidData[4], uuidData[5], uuidData[6], uuidData[7], uuidData[8], uuidData[9], uuidData[10], uuidData[11], uuidData[12], uuidData[13], uuidData[14], uuidData[15]))
            
            let seqData = data.dropFirst(16).prefix(2)
            self.sequenceNumber = seqData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            
            let totalData = data.dropFirst(18).prefix(2)
            self.totalChunks = totalData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        }
        
        var encoded: Data {
            var data = Data()
            withUnsafeBytes(of: transactionId.uuid) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: sequenceNumber.bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: totalChunks.bigEndian) { data.append(contentsOf: $0) }
            return data
        }
    }
    
    private struct PendingMessage {
        var chunks: [UInt16: Data]
        var totalChunks: UInt16
        var lastUpdate: Date
    }
    
    private var pendingMessages: [UUID: PendingMessage] = [:]
    private var processedTransactions: Set<UUID> = [] // NEW: Dedup cache
    private let cleanupInterval: TimeInterval = 30
    private var lastCleanupTime = Date()
    
    // Max safe UDP payload (allow overhead for IP/UDP headers)
    // IPv4 header (20) + UDP header (8) + ChunkHeader (20) = 48 bytes overhead minimum
    // MTU is often 1500. "Message too long" (EMSGSIZE) occurs if we exceed interface MTU on some config.
    // We strictly limit packet size to fit standard Ethernet MTU (1500) to ensure delivery validation.
    // 1450 is safe (1500 - 20 IP - 8 UDP - 22 Safety).
    // Let's use 1400 to be extremely safe and allow extra headers.
    private let maxChunkSize = 1400
    
    // ... existing start/stop ...
    
    func send(data: Data) {
        guard isRunning, socketFD >= 0 else { return }
        
        // Split data into chunks
        let totalLen = data.count
        let chunkCount = Int(ceil(Double(totalLen) / Double(maxChunkSize)))
        
        guard chunkCount <= UInt16.max else {
            print("Error: Data too large to send (\(totalLen) bytes)")
            return
        }
        
        let transactionId = UUID()
        let totalChunks = UInt16(chunkCount)
        
        // print("Sending \(totalLen) bytes in \(totalChunks) chunks (ID: \(transactionId))")
        
        for i in 0..<chunkCount {
            let start = i * maxChunkSize
            let end = min(start + maxChunkSize, totalLen)
            let chunkPayload = data.subdata(in: start..<end)
            
            let header = ChunkHeader(transactionId: transactionId, sequenceNumber: UInt16(i), totalChunks: totalChunks)
            var packet = header.encoded
            packet.append(chunkPayload)
            
            sendPacket(packet)
            
            // Pacing: Small delay to prevent flooding socket buffer and causing packet loss
            usleep(2000) // 2ms delay (~30MB/s throughput cap, sufficient for reliability)
        }
    }
    
    private func sendPacket(_ data: Data) {
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = port.bigEndian
        inet_pton(AF_INET, multicastGroupAddress, &dst.sin_addr)
        dst.sin_zero = (0, 0, 0, 0, 0, 0, 0, 0)
        
        let dstLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let sent = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &dst) { dstPtr in
                dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reb in
                    sendto(socketFD, ptr.baseAddress, data.count, 0, reb, dstLen)
                }
            }
        }
        
        if sent < 0 {
            print("Send failed: \(String(cString: strerror(errno)))")
        }
    }
    
    // MARK: - Private Setup
    
    private func setupSocket() {
        socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            print("Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }
        
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        // Try SO_REUSEPORT (Apple specific for multiple apps on same port)
        if setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            print("SO_REUSEPORT failed (might be expected on some platforms)")
        }
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reb in
                bind(socketFD, reb, addrLen)
            }
        }
        
        guard bindResult == 0 else {
            print("Bind failed: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }
        
        // Join Multicast Group on ALL interfaces (The Fix for Simulator)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            guard let firstAddr = ifaddr else { return }
            
            for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                let addr = ptr.pointee.ifa_addr.pointee
                
                // Check for IPv4 interface that is UP and RUNNING
                if addr.sa_family == UInt8(AF_INET) &&
                   (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING) {
                    
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        let ifName = String(cString: ptr.pointee.ifa_name)
                        print("Joining multicast group on \(ifName) (\(ip))")
                        
                        var mreq = ip_mreq()
                        inet_pton(AF_INET, multicastGroupAddress, &mreq.imr_multiaddr)
                        inet_pton(AF_INET, ip, &mreq.imr_interface)
                        
                        // Ignore errors for individual interfaces, just try them all
                        let _ = setsockopt(socketFD, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        
        // --- TX Configuration (Fix for "No route to host") ---
        
        // 1. Set Outgoing Interface (IP_MULTICAST_IF)
        // We find the active Wi-Fi/Ethernet interface request the socket to use it.
        if let interfaceIP = getInterfaceAddress() {
            var interfaceAddr = in_addr()
            inet_pton(AF_INET, interfaceIP, &interfaceAddr)
            let ifSetResult = setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_IF, &interfaceAddr, socklen_t(MemoryLayout<in_addr>.size))
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
        let ttlResult = setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        if ttlResult != 0 {
            print("Failed to set TTL: \(String(cString: strerror(errno)))")
        }
        
        // 3. Enable Loopback
        var loop: UInt8 = 1
        setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
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
            
            // Check for running IPv4 interface that is not loopback
            if (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if (getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, 0, NI_NUMERICHOST) == 0) {
                        let ipAsString = String(cString: hostname)
                        let name = String(cString: ptr.pointee.ifa_name)
                        
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
            guard let fd = await self.getSocketFD() else { return }
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
                    await self.processReceivedPacket(receivedData)
                } else {
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            }
        }
    }
    
    private func processReceivedPacket(_ data: Data) {
        // Parse Header
        guard let header = ChunkHeader(data: data) else { return }
        
        // Deduplication Check
        if processedTransactions.contains(header.transactionId) {
            // Already processed this transaction
            return
        }
        
        let payload = data.dropFirst(ChunkHeader.size)
        
        // Check cleanup
        if Date().timeIntervalSince(lastCleanupTime) > cleanupInterval {
            cleanupPendingMessages()
            lastCleanupTime = Date()
        }
        
        if header.totalChunks == 1 {
            // Single packet optimization
            processedTransactions.insert(header.transactionId) // Mark processed
            publishData(payload)
            return
        }
        
        // Multi-packet assembly
        if pendingMessages[header.transactionId] == nil {
            pendingMessages[header.transactionId] = PendingMessage(chunks: [:], totalChunks: header.totalChunks, lastUpdate: Date())
        }
        
        pendingMessages[header.transactionId]?.chunks[header.sequenceNumber] = payload
        pendingMessages[header.transactionId]?.lastUpdate = Date()
        
        // Check for completion
        if let pending = pendingMessages[header.transactionId], pending.chunks.count == pending.totalChunks {
            // Reassemble
            var fullData = Data()
            for i in 0..<pending.totalChunks {
                if let part = pending.chunks[i] {
                    fullData.append(part)
                }
            }
            
            processedTransactions.insert(header.transactionId) // Mark processed
            publishData(fullData)
            pendingMessages.removeValue(forKey: header.transactionId)
        }
    }
    
    private func cleanupPendingMessages() {
        let now = Date()
        let timeout: TimeInterval = 30
        
        let expired = pendingMessages.filter { now.timeIntervalSince($0.value.lastUpdate) > timeout }
        for (id, _) in expired {
            pendingMessages.removeValue(forKey: id)
        }
        
        // Cleanup processed cache too rarely?
        // Actually we should remove processed IDs after some time to prevent infinite growth
        // Let's just create a new set if it gets too big or clear it periodically if we had timestamps.
        // For simplicity, we'll clear processedTransactions every cleanup cycle if they're old... 
        // But we don't have timestamps for processedTransactions. 
        // Simple heuristic: If processedTransactions > 1000, clear it? Or just clear it with pendingMessages?
        // If we clear it, duplicates might reappear if replayed.
        // Let's rely on the fact that UDP packets usually arrive within seconds.
        // Resetting the set every 30s is probably fine for "recent" duplicates.
        if processedTransactions.count > 1000 {
            processedTransactions.removeAll()
        }
    }
    
    // Helpers for detached task access
    private func getSocketFD() -> Int32? {
        return socketFD >= 0 ? socketFD : nil
    }
    
    private func getIsRunning() -> Bool {
        return isRunning
    }
    
    private func publishData(_ data: Data) {
        for (_, continuation) in continuations {
            continuation.yield(data)
        }
    }
}
