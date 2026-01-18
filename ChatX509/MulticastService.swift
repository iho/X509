//
//  MulticastService.swift
//  chat509
//
//  Created on 14.01.2026.
//

import Foundation
import Network

/// Handles UDP Multicast networking for the chat application (Network Looper)
final class MulticastService: @unchecked Sendable {
    static let shared = MulticastService()
    
    // MARK: - Configuration
    static let BROADCAST_GROUP = "239.1.42.1"     // For Discovery
    static let CHAT_GROUP = "239.1.42.28"         // For Chat & Files
    
    private let port: UInt16 = 55555
    private let bufferSize = 65536
    private let maxChunkSize = 1024
    
    // MARK: - State (Thread-Safe)
    private let stateLock = NSLock()
    private var isRunning = false
    private var receiveSocketFD: Int32 = -1
    private var sendSocketFD: Int32 = -1
    
    // Stats
    private var totalBytesSent = 0
    private var totalBytesReceived = 0
    private var selectedInterfaceIP: String? // New field

    // ...

    // Debug Stats
    struct DebugStats {
        let isRunning: Bool
        let totalBytesSent: Int
        let totalBytesReceived: Int
        let pendingMessagesCount: Int
        let selectedInterfaceIP: String? // New field
    }
    
    func getDebugStats() -> DebugStats {
        stateLock.lock()
        defer { stateLock.unlock() }
        return DebugStats(
            isRunning: isRunning,
            totalBytesSent: totalBytesSent,
            totalBytesReceived: totalBytesReceived,
            pendingMessagesCount: pendingMessages.count,
            selectedInterfaceIP: selectedInterfaceIP
        )
    }
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    
    // Send Queue
    private var sendStreamContinuation: AsyncStream<SendRequest>.Continuation?
    
    private struct SendRequest {
        let data: Data
        let address: String
    }
    
    // Chunk Header structure (Wire Protocol)
    private struct ChunkHeader {
        let transactionId: UUID
        let sequenceNumber: UInt16
        let totalChunks: UInt16
        let type: UInt8 // 0 = Data, 1 = NACK (unused now but kept for wire compat)
        
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
    
    // Reassembly State
    private struct PendingMessage {
        var chunks: [UInt16: Data]
        var totalChunks: UInt16
        var lastUpdate: Date
    }
    private var pendingMessages: [UUID: PendingMessage] = [:]
    private var processedTransactions: Set<UUID> = []
    
    // MARK: - Initialization
    private init() {
        // Initialize Send Queue Stream
        let (stream, continuation) = AsyncStream<SendRequest>.makeStream()
        self.sendStreamContinuation = continuation
        
        // Start Send Loop
        Task.detached { [weak self] in
            await self?.runSendLoop(stream: stream)
        }
    }
    
    // MARK: - Public API
    
    private var isStarting = false

    func start() {
        stateLock.lock()
        if isRunning || isStarting {
            stateLock.unlock()
            return
        }
        isStarting = true
        stateLock.unlock()
        
        // Setup Socket (No lock held)
        let (rx, tx) = prepareSockets()
        
        stateLock.lock()
        isStarting = false
        // Check if stopped while setting up (isRunning should be false, but meaningful if we supported cancellation during start)
        // Also check if prepareSockets succeeded
        if rx >= 0 && tx >= 0 {
            isRunning = true
            receiveSocketFD = rx
            sendSocketFD = tx
            print("MulticastService started. Listening on \(MulticastService.BROADCAST_GROUP) and \(MulticastService.CHAT_GROUP). Port: \(port)")
            startListening()
            startMaintenanceLoop()
            startNetworkMonitoring()
        } else {
             print("MulticastService failed to start sockets.")
             if rx >= 0 { close(rx) }
             if tx >= 0 { close(tx) }
        }
        stateLock.unlock()
    }
    
    func stop() {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = false
        
        if receiveSocketFD >= 0 {
            close(receiveSocketFD)
            receiveSocketFD = -1
        }
        if sendSocketFD >= 0 {
            close(sendSocketFD)
            sendSocketFD = -1
        }
        stateLock.unlock()
        
        monitor?.cancel()
        monitor = nil
        maintenanceTask?.cancel()
    }
    
    func send(data: Data, address: String = MulticastService.CHAT_GROUP) {
        // Non-blocking yield
        sendStreamContinuation?.yield(SendRequest(data: data, address: address))
    }
    
    /// Returns a new stream for receiving data. Each caller gets their own stream.
    var dataStream: AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            self?.addContinuation(id: id, continuation: continuation)
            
            continuation.onTermination = { _ in
                self?.removeContinuation(id: id)
            }
        }
    }
    
    // MARK: - Internal Logic
    
    nonisolated private func addContinuation(id: UUID, continuation: AsyncStream<Data>.Continuation) {
        stateLock.lock()
        defer { stateLock.unlock() }
        continuations[id] = continuation
    }
    
    nonisolated private func removeContinuation(id: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        continuations.removeValue(forKey: id)
    }
    
    private func runSendLoop(stream: AsyncStream<SendRequest>) async {
        for await request in stream {
             await processSendRequest(request)
        }
    }
    
    private func processSendRequest(_ request: SendRequest) async {
        let maxChunkSize = 1024
        let totalLen = request.data.count
        let chunkCount = Int(ceil(Double(totalLen) / Double(maxChunkSize)))
        
        if chunkCount > UInt16.max {
             print("Error: Data too large to send")
             return
        }
        
        let transactionId = UUID()
        let totalChunks = UInt16(chunkCount)
        
        for i in 0..<chunkCount {
            let start = i * maxChunkSize
            let end = min(start + maxChunkSize, totalLen)
            let chunkPayload = request.data.subdata(in: start..<end)
            
            let header = ChunkHeader(transactionId: transactionId, sequenceNumber: UInt16(i), totalChunks: totalChunks, type: 0)
            var packet = header.encoded
            packet.append(chunkPayload)
            
            sendPacket(packet, address: request.address)
            
            // Pacing
            if i % 10 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms every 10 packets
            }
            try? await Task.sleep(nanoseconds: 2_000_000) // 2ms pacing per packet
        }
    }
    
    private func sendPacket(_ data: Data, address: String) {
        stateLock.lock()
        let fd = sendSocketFD
        stateLock.unlock()
        
        guard fd >= 0 else { return }
        
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
                    sendto(fd, ptr.baseAddress, data.count, 0, reb, dstLen)
                }
            }
        }
        
        if sent > 0 {
            stateLock.lock()
            totalBytesSent += sent
            stateLock.unlock()
        }
    }
    
    private let receiveQueue = DispatchQueue(label: "com.chatx509.multicast.receive", qos: .userInitiated)

    private func startListening() {
        receiveQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Wait for socket to be ready
            var fd: Int32 = -1
            while fd < 0 {
                self.stateLock.lock()
                if self.receiveSocketFD >= 0 { fd = self.receiveSocketFD }
                let running = self.isRunning
                self.stateLock.unlock()
                
                if !running { return }
                if fd < 0 { Thread.sleep(forTimeInterval: 0.05) }
            }
            
            var buffer = [UInt8](repeating: 0, count: 65536)
            
            while true {
                 self.stateLock.lock()
                 let running = self.isRunning
                 self.stateLock.unlock()
                 if !running { break }
                 
                 var sender = sockaddr_storage()
                 var senderLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                 
                 // Blocking Receive (System Thread, not Task Pool)
                 let bytesRead = withUnsafeMutablePointer(to: &sender) { senderPtr in
                     senderPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebPtr in
                         recvfrom(fd, &buffer, buffer.count, 0, rebPtr, &senderLen)
                     }
                 }
                 
                 if bytesRead > 0 {
                     let receivedData = Data(buffer[0..<bytesRead])
                     self.processReceivedPacket(receivedData)
                     
                     self.stateLock.lock()
                     self.totalBytesReceived += bytesRead
                     self.stateLock.unlock()
                 } else {
                     // If recvfrom failed (e.g. socket closed), brief Sleep
                     Thread.sleep(forTimeInterval: 0.1)
                 }
            }
        }
    }
    
    private func processReceivedPacket(_ data: Data) {
        // Wire Protocol Parsing
        guard let header = ChunkHeader(data: data) else { return }
        
        // Ignore NACKs (Type 1) in Receive Looper as per V1 simplifications
        if header.type == 1 { return }
        
        stateLock.lock()
        defer { stateLock.unlock() }
        
        if processedTransactions.contains(header.transactionId) { return }
        
        let payload = data.dropFirst(ChunkHeader.size)
        
        // Single Chunk
        if header.totalChunks == 1 {
            processedTransactions.insert(header.transactionId)
            publishData(payload)
            return
        }
        
        // Multi Chunk Reassembly
        if pendingMessages[header.transactionId] == nil {
             pendingMessages[header.transactionId] = PendingMessage(chunks: [:], totalChunks: header.totalChunks, lastUpdate: Date())
        }
        
        pendingMessages[header.transactionId]?.chunks[header.sequenceNumber] = payload
        pendingMessages[header.transactionId]?.lastUpdate = Date()
        
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
    
    private func publishData(_ data: Data) {
        // Must be called under lock
        for (_, continuation) in continuations {
            continuation.yield(data)
        }
    }
    
    // MARK: - Setup & Maintenance
    
    // Returns (receiveFD, sendFD)
    private func prepareSockets() -> (Int32, Int32) {
        // RX
        var rxFD: Int32 = -1
        let rfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if rfd >= 0 {
            var reuse: Int32 = 1
            setsockopt(rfd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(rfd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
            
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = 0 // INADDR_ANY
            
            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reb in
                    bind(rfd, reb, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            
            if bindRes == 0 {
                 joinMulticastGroup(fd: rfd, address: MulticastService.BROADCAST_GROUP)
                 joinMulticastGroup(fd: rfd, address: MulticastService.CHAT_GROUP)
                 rxFD = rfd
            } else {
                 print("RX Bind Failed")
                 close(rfd)
            }
        }
        
        // TX
        var txFD: Int32 = -1
        let sfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if sfd >= 0 {
            var reuse: Int32 = 1
            setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sfd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sfd, SOL_SOCKET, SO_BROADCAST, &reuse, socklen_t(MemoryLayout<Int32>.size))
            
            // Defaults
            var ttl: UInt8 = 255
            setsockopt(sfd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
            var loop: UInt8 = 1
            setsockopt(sfd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
            
            configureOutgoingInterface(fd: sfd)
            txFD = sfd
        }
        
        return (rxFD, txFD)
    }
    
    private func joinMulticastGroup(fd: Int32, address: String) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            print("MulticastService: Failed to getifaddrs")
            return
        }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            let name = String(cString: ptr.pointee.ifa_name)
            
            // Relaxed check: UP and NOT Loopback (consistent with configureOutgoingInterface)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            
            if addr.sa_family == UInt8(AF_INET) && isUp && !isLoopback {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    // Filter out virtual/vpn interfaces which often swallow multicast
                    if name.hasPrefix("utun") || name.hasPrefix("llw") || name.hasPrefix("awdl") {
                        continue
                    }
                    
                    let ip = String(cString: hostname)
                    
                    // Skip 127.x explicitly if not caught by loopback flag
                    if ip.hasPrefix("127.") { continue }
                    
                    var mreq = ip_mreq()
                    inet_pton(AF_INET, address, &mreq.imr_multiaddr)
                    inet_pton(AF_INET, ip, &mreq.imr_interface)
                    
                    let result = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
                    if result == 0 {
                        print("MulticastService: Joined \(address) on interface \(name) (\(ip))")
                    } else {
                        // It's normal to fail on some interfaces (already joined, etc)
                        // print("MulticastService: Failed to join \(address) on \(name) (\(ip)): \(errno)")
                    }
                }
            }
        }
    }
    
    private func configureOutgoingInterface(fd: Int32) {
        // Find best multicast-capable IPv4 interface
        // Prioritize "en0" (WiFi), then "en1", "bridge100", etc.
        // We look for Interface that is UP and NOT Loopback.
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            print("[Multicast] Failed to getifaddrs")
            return
        }
        defer { freeifaddrs(ifaddr) }
        
        var bestIP: String?
        var foundEn0 = false
        
        print("[Multicast] Scanning interfaces for outgoing config...")
        
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            let name = String(cString: ptr.pointee.ifa_name)
            
            // Basic Requirement: UP and NOT Loopback
            // (We removed strict RUNNING/MULTICAST check to be more permissive on iOS HW)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            
            if !isUp || isLoopback { continue }
            
            if addr.sa_family == UInt8(AF_INET) {
                // Use numeric-only conversion to avoid DNS blocks
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    // Skip 127.x.x.x just in case
                    if ip.hasPrefix("127.") { continue }
                    
                    // Filter out virtual/vpn interfaces which often swallow multicast
                    if name.hasPrefix("utun") || name.hasPrefix("llw") || name.hasPrefix("awdl") {
                        continue
                    }
                    
                    print("[Multicast] Found candidate: \(name) - \(ip)")
                    
                    // Prioritize "en" (Ethernet/WiFi) interfaces
                    // This applies to both iOS and macOS to avoid VPN tunnels
                    if name.hasPrefix("en") {
                        bestIP = ip
                        foundEn0 = true // Treat any 'en' as a gold standard candidate
                        break 
                    }
                    
                    if !foundEn0 {
                        // Keep first valid interface found as candidate
                        if bestIP == nil { bestIP = ip }
                    }
                }
            }
        }
        
        if let ip = bestIP {
            var addr = in_addr()
            inet_pton(AF_INET, ip, &addr)
            let result = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size))
            if result == 0 {
                print("[Multicast] Set outgoing multicast interface to: \(ip)")
                stateLock.lock()
                self.selectedInterfaceIP = ip
                stateLock.unlock()
            } else {
                 print("[Multicast] Failed to set outgoing interface \(ip): \(errno)")
            }
        } else {
            // Explicitly default to system routing if scan failed
            print("[Multicast] WARNING: No suitable IPv4 multicast interface found! Using system defaults.")
            stateLock.lock()
            self.selectedInterfaceIP = "System Default (Scan Failed)"
            stateLock.unlock()
        }
    }
    
    // MARK: - Maintenance (Cleanup Old Pending)
    private var maintenanceTask: Task<Void, Never>?
    
    private func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard let self = self else { break }
                
                self.stateLock.lock()
                if !self.isRunning {
                    self.stateLock.unlock()
                    break
                }
                
                let now = Date()
                // Cleanup old pending
                let expired = self.pendingMessages.filter { now.timeIntervalSince($0.value.lastUpdate) > 60 }
                for (id, _) in expired { self.pendingMessages.removeValue(forKey: id) }
                
                // Cleanup processed cache
                if self.processedTransactions.count > 1000 {
                    self.processedTransactions.removeAll()
                }
                self.stateLock.unlock()
            }
        }
    }
    
    // MARK: - Network Monitoring
    private var monitor: NWPathMonitor?
    
    private func startNetworkMonitoring() {
        monitor?.cancel()
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                 self?.checkRestart(path: path)
            }
        }
        let queue = DispatchQueue(label: "NetworkMonitor")
        pathMonitor.start(queue: queue)
        monitor = pathMonitor
    }
    
    private func checkRestart(path: NWPath) {
        // Implement restart logic if needed (IP changed, etc.)
        // This runs on NetworkMonitor queue.
        // We can just log or restart if we tracked last IP.
    }
    
    func restart() async {
        stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        start()
        
        // Announce immediately
        await UserDiscoveryService.shared.restart()
    }
    

}
