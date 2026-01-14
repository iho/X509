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
    
    init(
        id: UUID = UUID(),
        name: String,
        certificateSubject: String,
        lastMessage: String? = nil,
        lastMessageDate: Date? = nil,
        unreadCount: Int = 0,
        isOnline: Bool = false
    ) {
        self.id = id
        self.name = name
        self.certificateSubject = certificateSubject
        self.lastMessage = lastMessage
        self.lastMessageDate = lastMessageDate
        self.unreadCount = unreadCount
        self.isOnline = isOnline
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
        let seedUsers = [
            ChatUser(
                name: "Alice",
                certificateSubject: "CN=alice,O=Chat509",
                lastMessage: "Hey! Ready to chat securely? 🔒",
                lastMessageDate: Date().addingTimeInterval(-300),
                unreadCount: 2,
                isOnline: true
            ),
            ChatUser(
                name: "Bob",
                certificateSubject: "CN=bob,O=Chat509",
                lastMessage: "The certificates are verified ✓",
                lastMessageDate: Date().addingTimeInterval(-3600),
                unreadCount: 0,
                isOnline: true
            ),
            ChatUser(
                name: "Charlie",
                certificateSubject: "CN=charlie,O=Chat509",
                lastMessage: "Talk later!",
                lastMessageDate: Date().addingTimeInterval(-86400),
                unreadCount: 0,
                isOnline: false
            )
        ]
        
        users = seedUsers
        saveUsers()
    }
}
