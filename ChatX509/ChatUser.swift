//
//  ChatUser.swift
//  chat509
//
//  Created on 24.12.2025.
//

import Foundation
import Combine

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
    
    func updateUser(_ user: ChatUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
            saveUsers()
        }
    }
    
    // MARK: - Discovery Methods
    
    /// Add or update a user discovered on the network
    func addOrUpdateDiscoveredUser(name: String, certificateData: Data, isOnline: Bool) {
        if let index = users.firstIndex(where: { $0.name == name }) {
            // Update existing user
            users[index].certificateData = certificateData
            users[index].lastSeen = Date()
            users[index].isOnline = isOnline
            users[index].isDiscovered = true
        } else {
            // Add new discovered user
            let newUser = ChatUser(
                name: name,
                certificateSubject: "CN=\(name)",
                isOnline: isOnline,
                certificateData: certificateData,
                lastSeen: Date(),
                isDiscovered: true
            )
            users.append(newUser)
        }
        saveUsers()
    }
    
    /// Mark a user as offline
    func markUserOffline(name: String) {
        if let index = users.firstIndex(where: { $0.name == name }) {
            users[index].isOnline = false
            saveUsers()
        }
    }
    
    /// Get user by name
    func getUserByName(_ name: String) -> ChatUser? {
        return users.first { $0.name == name }
    }
    
    /// Get certificate data for a user
    func getCertificateData(for userName: String) -> Data? {
        return users.first { $0.name == userName }?.certificateData
    }
    
    // MARK: - Private Methods
    
    private func startUserDiscovery() {
        Task {
            await UserDiscoveryService.shared.start(
                onUserDiscovered: { [weak self] discoveredUser in
                    Task { @MainActor in
                        self?.addOrUpdateDiscoveredUser(
                            name: discoveredUser.username,
                            certificateData: discoveredUser.certificateData,
                            isOnline: discoveredUser.isOnline
                        )
                    }
                },
                onUserOffline: { [weak self] username in
                    Task { @MainActor in
                        self?.markUserOffline(name: username)
                    }
                }
            )
        }
    }
    
    private func saveUsers() {
        if let data = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(data, forKey: storageKey)
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

