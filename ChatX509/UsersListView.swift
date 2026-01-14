//
//  UsersListView.swift
//  chat509
//
//  Created on 24.12.2025.
//

import SwiftUI

struct UsersListView: View {
    @StateObject private var userStore = ChatUserStore.shared
    @State private var activeSheet: ActiveSheet?
    @State private var selectedUser: ChatUser?
    
    enum ActiveSheet: Identifiable {
        case addUser
        case loginEnroll
        case logoutRevoke
        
        var id: Int { hashValue }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color(red: 0.1, green: 0.1, blue: 0.2),
                        Color(red: 0.05, green: 0.05, blue: 0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                if userStore.users.isEmpty {
                    emptyStateView
                } else {
                    userListContent
                }
            }
            .navigationTitle("Chats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    addUserButton
                }
                ToolbarItem(placement: .cancellationAction) {
                    settingsMenu
                }
            }
            #if os(macOS)
            .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
            #endif
            // .toolbarColorScheme(.dark, for: .navigationBar) // navigationBar unavailable on macOS
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addUser:
                AddUserView()
            case .loginEnroll:
                LoginEnrollView()
            case .logoutRevoke:
                LogoutRevokeView()
            }
        }
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)
                
                Image(systemName: "person.2.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            VStack(spacing: 8) {
                Text("No Contacts Yet")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                
                Text("Add your first contact to start\na secure conversation")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            
            Button(action: { activeSheet = .addUser }) {
                Label("Add Contact", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
            }
        }
    }
    
    // MARK: - User List
    private var userListContent: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(userStore.users) { user in
                    NavigationLink(destination: ChatView(user: user)) {
                        UserRowView(user: user)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }
    
    // MARK: - Toolbar Buttons
    private var addUserButton: some View {
        Button(action: { activeSheet = .addUser }) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
    
    private var settingsMenu: some View {
        Menu {
            Button(action: { activeSheet = .loginEnroll }) {
                Label("Login / Enroll", systemImage: "person.badge.key")
            }
            
            Button(action: { activeSheet = .logoutRevoke }) {
                Label("Logout / Revoke", systemImage: "rectangle.portrait.and.arrow.right")
            }
            
            Button(action: { /* Search TODO */ }) {
                Label("Search", systemImage: "magnifyingglass")
            }
            
            Divider()
            
            Button(role: .destructive, action: { /* Quit TODO */ exit(0) }) {
                Label("Quit Chat", systemImage: "power")
            }
        } label: {
            Image(systemName: "line.3.horizontal.circle")
                .font(.body)
                .foregroundColor(.gray)
        }
    }
}

// MARK: - User Row View
struct UserRowView: View {
    let user: ChatUser
    
    var body: some View {
        HStack(spacing: 14) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: avatarColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                
                Text(user.name.prefix(1).uppercased())
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                
                // Online indicator
                if user.isOnline {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .stroke(Color(red: 0.1, green: 0.1, blue: 0.2), lineWidth: 3)
                        )
                        .offset(x: 18, y: 18)
                }
            }
            
            // User info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(user.name)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    // Discovered badge
                    if user.isDiscovered {
                        Text("Discovered")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    
                    // Encryption ready indicator
                    if user.certificateData != nil {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    if let date = user.lastMessageDate {
                        Text(formatDate(date))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                HStack {
                    Text(user.lastMessage ?? user.certificateSubject)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if user.unreadCount > 0 {
                        Text("\(user.unreadCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05))
        .contentShape(Rectangle())
    }
    
    private var avatarColors: [Color] {
        let colorSets: [[Color]] = [
            [.blue, .purple],
            [.purple, .pink],
            [.orange, .red],
            [.green, .teal],
            [.teal, .blue]
        ]
        let index = abs(user.name.hashValue) % colorSets.count
        return colorSets[index]
    }
    
    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd/MM"
            return formatter.string(from: date)
        }
    }
}

#Preview {
    UsersListView()
}
