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
    
    // Message Stream
    private var dataContinuation: AsyncStream<Data>.Continuation?
    
    var dataStream: AsyncStream<Data> {
        AsyncStream { continuation in
            self.dataContinuation = continuation
        }
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
    
    func send(data: Data) {
        guard isRunning, socketFD >= 0 else { return }
        
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
        
        // Join Multicast Group
        var mreq = ip_mreq()
        inet_pton(AF_INET, multicastGroupAddress, &mreq.imr_multiaddr)
        mreq.imr_interface.s_addr = INADDR_ANY
        
        let joinResult = setsockopt(socketFD, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        if joinResult != 0 {
            print("Failed to join multicast group: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }
    }
    
    private func startListening() {
        Task.detached {
            guard let fd = await self.getSocketFD() else { return }
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
                    await self.publishData(receivedData)
                } else {
                    // if recvfrom fails or returns 0, maybe pause slightly or check error
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
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
        dataContinuation?.yield(data)
    }
}
