//
//  ChatUser.swift
//  chat509
//
//  Created on 24.12.2025.
//

import Foundation
import Combine
import SwiftASN1

/// Represents a chat user/contact
struct ChatUser: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var certificateSubject: String // e.g., "CN=alice,O=Example"
    var lastMessage: String?
    var lastMessageDate: Date?
    var unreadCount: Int
    var isOnline: Bool
    
    // New fields for CMS encryption and discovery
    var certificateData: Data?  // DER-encoded X.509 certificate for encryption
    var serialNumber: Data?     // Certificate serial number for unique identification
    var lastSeen: Date?         // Last time user was seen on network
    var isDiscovered: Bool      // true = auto-discovered, false = manually added
    
    init(
        id: UUID = UUID(),
        name: String,
        certificateSubject: String,
        lastMessage: String? = nil,
        lastMessageDate: Date? = nil,
        unreadCount: Int = 0,
        isOnline: Bool = false,
        certificateData: Data? = nil,
        serialNumber: Data? = nil,
        lastSeen: Date? = nil,
        isDiscovered: Bool = false
    ) {
        self.id = id
        self.name = name
        self.certificateSubject = certificateSubject
        self.lastMessage = lastMessage
        self.lastMessageDate = lastMessageDate
        self.unreadCount = unreadCount
        self.isOnline = isOnline
        self.certificateData = certificateData
        self.serialNumber = serialNumber
        self.lastSeen = lastSeen
        self.isDiscovered = isDiscovered
    }
}

/// Manages the list of chat users
@MainActor
final class ChatUserStore: ObservableObject {
    static let shared = ChatUserStore()
        
    @Published var users: [ChatUser] = []
    
    private let storageKey = "chatUsers"
    
    private init() {
        loadUsers()
        if users.isEmpty {
            seedDefaultUsers()
        }
        startUserDiscovery() 
    }
    
    func addUser(_ user: ChatUser) {
        users.append(user)
        saveUsers()
    }
    
    func removeUser(_ user: ChatUser) {
        users.removeAll { $0.id == user.id }
        saveUsers()
    }
    
    /// Mark a user as offline by serial number
    func markUserOffline(serialNumber: Data) {
        if let index = users.firstIndex(where: { $0.serialNumber == serialNumber }) {
            users[index].isOnline = false
            scheduleSave()
        }
    }
    
    /// Legacy: Mark a user as offline by name (if serial unknown)
    func markUserOffline(name: String) {
        if let index = users.firstIndex(where: { $0.name == name }) {
            users[index].isOnline = false
            scheduleSave()
        }
    }
    
    func updateUser(_ user: ChatUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
            saveUsers()
        }
    }
    
    /// Mark a user's messages as read (clear unread count)
    func markAsRead(_ user: ChatUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index].unreadCount = 0
            saveUsers()
        }
    }
    
    /// Clear all users AND their messages
    func clearAll() {
        clearAllMessages()
        users.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
        print("All users and messages cleared")
    }
    
    /// Clear messages for ALL users but keep the users list
    func clearAllMessages() {
        objectWillChange.send() // Force UI update
        for user in users {
            removeMessages(for: user)
        }
        // Update user previews
        for i in 0..<users.count {
            users[i].lastMessage = nil
            users[i].lastMessageDate = nil
            users[i].unreadCount = 0
        }
        saveUsers()
        print("All chat messages cleared")
    }
    
    /// Remove a single chat (messages only)
    func clearMessages(for user: ChatUser) {
        removeMessages(for: user)
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index].lastMessage = nil
            users[index].lastMessageDate = nil
            users[index].unreadCount = 0
            saveUsers()
        }
    }
    
    private func removeMessages(for user: ChatUser) {
        let messageKey = "messages_\(user.id.uuidString)"
        UserDefaults.standard.removeObject(forKey: messageKey)
    }

    /// Get user by name
    func getUserByName(_ name: String) -> ChatUser? {
        return users.first { $0.name == name }
    }
    
    /// Get certificate data for a user
    func getCertificateData(for userName: String) -> Data? {
        return users.first { $0.name == userName }?.certificateData
    }
    
    // MARK: - Discovery Methods
    
    /// Add or update a user discovered on the network
    /// Add or update a user discovered on the network
    func addOrUpdateDiscoveredUser(name: String, certificateSubject: String, certificateData: Data, serialNumber: Data, isOnline: Bool) {
        
        // 1. Try to find by serial number (exact identity match)
        if let index = users.firstIndex(where: { $0.serialNumber == serialNumber }) {
            // Update fields
            var changed = false
            if users[index].name != name { users[index].name = name; changed = true }
            if users[index].certificateSubject != certificateSubject { users[index].certificateSubject = certificateSubject; changed = true }
            if users[index].isOnline != isOnline { users[index].isOnline = isOnline; changed = true }
            // Only update lastSeen if changed significantly (e.g. > 60s) to avoid UI churn
            if let last = users[index].lastSeen {
                if Date().timeIntervalSince(last) > 30 {
                    users[index].lastSeen = Date()
                    // Don't mark as changed for save just for lastSeen update? 
                    // Or do we want to persist it? Persisting constantly is bad.
                    // Let's rely on internal state for timeout, save only periodically.
                }
            } else {
                users[index].lastSeen = Date()
                changed = true
            }
            
            if changed { scheduleSave() }
        } 
        // 2. Try to find by name (identity rotation/regeneration case)
        else if let index = users.firstIndex(where: { $0.name == name }) {
            print("User '\(name)' rotated identity (new serial). Updating credentials.")
            users[index].serialNumber = serialNumber
            users[index].certificateSubject = certificateSubject
            users[index].certificateData = certificateData
            users[index].lastSeen = Date()
            users[index].isOnline = isOnline
            scheduleSave()
        }
        // 3. New user
        else {
            let newUser = ChatUser(
                name: name,
                certificateSubject: certificateSubject,
                isOnline: isOnline,
                certificateData: certificateData,
                serialNumber: serialNumber,
                lastSeen: Date(),
                isDiscovered: true
            )
            users.append(newUser)
            scheduleSave()
        }
    }
    
    // Debounce Save (2 seconds)
    private var saveWorkItem: DispatchWorkItem?
    
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveUsers()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }
    
    // ... markUserOffline also needs to call scheduleSave()
    
    private func startUserDiscovery() {
        Task.detached {
            await UserDiscoveryService.shared.start(
                onUserDiscovered: { discoveredUser in
                    Task { @MainActor in
                        ChatUserStore.shared.addOrUpdateDiscoveredUser(
                            name: discoveredUser.username,
                            certificateSubject: discoveredUser.certificateSubject,
                            certificateData: discoveredUser.certificateData,
                            serialNumber: discoveredUser.serialNumber,
                            isOnline: discoveredUser.isOnline
                        )
                    }
                },
                onUserOffline: { username, serial in
                    Task { @MainActor in
                        if let serial = serial {
                            ChatUserStore.shared.markUserOffline(serialNumber: serial)
                        } else {
                            ChatUserStore.shared.markUserOffline(name: username)
                        }
                    }
                }
            )
        }
    }
    
    private let saveQueue = DispatchQueue(label: "com.chatx509.userstore.save", qos: .background)
    
    private func saveUsers() {
        let snapshot = self.users
        let key = self.storageKey
        
        saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
    
    private func loadUsers() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ChatUser].self, from: data) else {
            return
        }
        users = decoded
    }
    
    private func seedDefaultUsers() {
        // No seed users - start with empty list
        // Users will be discovered via network or added manually
        users = []
        saveUsers()
    }
}

