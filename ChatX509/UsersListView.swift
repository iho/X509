//
//  UsersListView.swift
//  chat509
//
//  Created on 24.12.2025.
//

import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import SwiftASN1

struct UsersListView: View {
    @ObservedObject private var userStore = ChatUserStore.shared
    @ObservedObject private var certificateManager = CertificateManager.shared
    @AppStorage("isDarkMode") private var isDarkMode = true
    @Environment(\.colorScheme) var colorScheme
    @State private var activeSheet: ActiveSheet?
    @State private var selectedUser: ChatUser?
    @State private var showKeyExporter = false
    @State private var exportKeyData: Data?
    @State private var keyOperationMessage: String?
    @State private var showOwnCertificate = false
    @State private var showExpirationAlert = false
    @State private var showDeleteAllConfirmation = false
    @State private var userToDelete: ChatUser?
    @State private var searchText = ""
    
    enum ActiveSheet: Identifiable {
        case addUser
        case loginEnroll
        case logoutRevoke
        case about
        case debug
        
        var id: Int { hashValue }
    }
    
    var body: some View {
        AnyNavigationStack {
            ZStack {
                // Background gradient
                if colorScheme == .dark {
                    LinearGradient(
                        colors: [
                            Color(red: 0.1, green: 0.1, blue: 0.2),
                            Color(red: 0.05, green: 0.05, blue: 0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [
                            Color(white: 0.95), // White-gray
                            Color.white
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
                
                VStack(spacing: 0) {
                    // Identity header
                    identityHeader                    
                    if userStore.users.isEmpty {
                        emptyStateView
                    } else {
                        userListContent
                    }
                }
            }
            .navigationTitle("Chats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .compatToolbarColorScheme(isDarkMode ? .dark : .light, for: .navigationBar)
            .compatToolbarBackground(isDarkMode ? Color(red: 0.1, green: 0.1, blue: 0.2) : Color(white: 0.95), for: .navigationBar)
            .compatToolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    addUserButton
                }
                ToolbarItem(placement: .cancellationAction) {
                    settingsMenu
                }
            }
            .alert("Identity Expired", isPresented: $showExpirationAlert) {
                Button("Regenerate", role: .destructive) {
                    print("[UI] Regenerate button tapped")
                    showExpirationAlert = false
                    // Ensure we don't block
                    Task {
                        CertificateManager.shared.generateNewIdentity()
                    }
                }
                Button("Cancel", role: .cancel) {
                    print("[UI] Cancel button tapped")
                    showExpirationAlert = false
                }
            } message: {
                Text("Your identity has expired. Other users won't be able to send you encrypted messages until you regenerate your certificate.")
            }
            .onReceive(CertificateManager.shared.$isExpired) { expired in
                // Only update if changed to avoid view refresh cycles
                if showExpirationAlert != expired {
                    print("[UI] isExpired changed to \(expired), updating alert")
                    showExpirationAlert = expired
                }
            }
            .alert("Delete Chat?", isPresented: .init(
                get: { userToDelete != nil },
                set: { if !$0 { userToDelete = nil } }
            ), presenting: userToDelete) { user in
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    userStore.removeUser(user)
                }
            } message: { user in
                Text("Are you sure you want to delete the chat history with \(user.name)? This action cannot be undone.")
            }
            .alert("Delete All Messages?", isPresented: $showDeleteAllConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete All", role: .destructive) {
                    userStore.clearAllMessages()
                }
            } message: {
                Text("This will wipe all chat history with all users. Your contacts will remain, but all messages will be deleted.")
            }
            #if os(macOS)
            .compatToolbarBackground(.ultraThinMaterial, for: .windowToolbar)
            #endif
            .searchable(text: $searchText, placement: .automatic, prompt: "Search users or organizations")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addUser:
                AddUserView()
            case .loginEnroll:
                LoginEnrollView()
            case .logoutRevoke:
                LogoutRevokeView()
            case .about:
                AboutView()
            case .debug:
                DebugView()
            }
        }
        .sheet(isPresented: $showOwnCertificate) {
            if let cert = CertificateManager.shared.currentCertificate {
                OwnCertificateSheet(certificate: cert)
            }
        }
    }
    
    // MARK: - Identity Header
    private var identityHeader: some View {
        Button(action: { showOwnCertificate = true }) {
            HStack(spacing: 12) {
                // Certificate icon
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ?
                             AnyShapeStyle(LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                             AnyShapeStyle(Color.gray.opacity(0.1))
                        )
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .foregroundColor(CertificateManager.shared.isExpired ? .red : .green)
                        .font(.system(size: 18))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in as")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Text(CertificateManager.shared.username.isEmpty ? "Not enrolled" : CertificateManager.shared.username)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                // Certificate status
                if CertificateManager.shared.currentCertificate != nil {
                    if CertificateManager.shared.isExpired {
                        Label("Expired", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.2))
                            .clipShape(Capsule())
                    } else {
                        Label("Valid", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)
                
                if colorScheme == .dark {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                } else {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                }
            }
            
            VStack(spacing: 8) {
                Text("No Contacts Yet")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.primary)
                
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
                        colorScheme == .dark ?
                        AnyShapeStyle(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)) :
                        AnyShapeStyle(Color.blue)
                    )
                    .clipShape(Capsule())
            }
        }
    }
    
    // MARK: - User List
    private var userListContent: some View {
        List {
            ForEach(sortedUsers) { user in
                ZStack {
                    NavigationLink(destination: ChatView(user: user)) {
                        EmptyView()
                    }
                    .opacity(0)
                    
                    UserRowView(user: user)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        userToDelete = user
                    } label: {
                        Label("Delete", systemImage: "trash.fill")
                    }
                }
            }
        }
        .listStyle(.plain)
        .padding(.top, 8)
    }
    
    /// Users sorted by most recent message first, then by online status
    private var sortedUsers: [ChatUser] {
        let filtered = userStore.users.filter { user in
            if searchText.isEmpty { return true }
            return user.name.localizedCaseInsensitiveContains(searchText) ||
                   user.certificateSubject.localizedCaseInsensitiveContains(searchText)
        }
        
        return filtered.sorted { a, b in
            // First by last message date (most recent first)
            if let dateA = a.lastMessageDate, let dateB = b.lastMessageDate {
                return dateA > dateB
            }
            // Users with messages come before those without
            if a.lastMessageDate != nil && b.lastMessageDate == nil { return true }
            if a.lastMessageDate == nil && b.lastMessageDate != nil { return false }
            // Then by online status
            if a.isOnline && !b.isOnline { return true }
            if !a.isOnline && b.isOnline { return false }
            // Finally alphabetically
            return a.name < b.name
        }
    }
    
    // MARK: - Toolbar Buttons
    private var addUserButton: some View {
        Button(action: { activeSheet = .addUser }) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(
                    colorScheme == .dark ?
                    AnyShapeStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                    AnyShapeStyle(Color.blue)
                )
        }
    }
    
    private var settingsMenu: some View {
        Menu {
            Button(action: { activeSheet = .loginEnroll }) {
                Label("Login / Enroll", systemImage: "person.badge.key")
            }
            
            Toggle(isOn: $isDarkMode) {
                Label("Dark Mode", systemImage: isDarkMode ? "moon.fill" : "sun.max.fill")
            }
            
            Button(action: { activeSheet = .logoutRevoke }) {
                Label("Logout / Revoke", systemImage: "rectangle.portrait.and.arrow.right")
            }
            
            Divider()
            
            Button(action: exportPrivateKey) {
                Label("Export Identity", systemImage: "square.and.arrow.up")
            }
            .disabled(CertificateManager.shared.currentPrivateKey == nil)
            
            Divider()
            
            Button(role: .destructive, action: { showDeleteAllConfirmation = true }) {
                Label("Delete All Messages", systemImage: "trash.slash")
            }
            
            Divider()
            
            Button(action: { /* Search TODO */ }) {
                Label("Search", systemImage: "magnifyingglass")
            }
            
            Divider()
            
            Button(role: .destructive, action: { exit(0) }) {
                Label("Quit Chat", systemImage: "power")
            }
            
            Divider()
            
            Button(action: { activeSheet = .debug }) {
                Label("Debug Tools", systemImage: "ladybug.fill")
            }
            
            Button(action: { activeSheet = .about }) {
                Label("About ChatX509", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "line.3.horizontal.circle")
                .font(.body)
                .foregroundColor(.gray)
        }
        // Force fileExporter to bind properly (unchanged)
        .fileExporter(
            isPresented: $showKeyExporter,
            document: KeyDocument(data: exportKeyData ?? Data()),
            contentType: .data,
            defaultFilename: "my_identity.p12"
        ) { result in
            handleKeyExport(result)
        }
        .alert("Key Operation", isPresented: .init(
            get: { keyOperationMessage != nil },
            set: { if !$0 { keyOperationMessage = nil } }
        )) {
            Button("OK") { keyOperationMessage = nil }
        } message: {
            Text(keyOperationMessage ?? "")
        }
    }
    
    private func exportPrivateKey() {
        guard let bundle = CertificateManager.shared.exportIdentity() else {
            keyOperationMessage = "No identity available to export"
            return
        }
        exportKeyData = bundle
        showKeyExporter = true
    }
    
    private func handleKeyImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                keyOperationMessage = "Cannot access file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let bundleData = try Data(contentsOf: url)
                
                // Try full identity bundle first
                // Now throwing, so we catch specific errors
                do {
                    try CertificateManager.shared.importIdentity(bundleData)
                    keyOperationMessage = "Identity imported successfully (key + certificate)"
                    return
                } catch let error as CertificateImportError {
                    // Start of P12 or format error
                    if error.localizedDescription.contains("Standard .p12") {
                        keyOperationMessage = error.localizedDescription
                        return
                    }
                    // Continue to fallback if just sizes didn't match, 
                    // BUT detecting standard P12 should be terminal to warn user.
                    if case .standardP12NotSupported = error {
                        keyOperationMessage = error.localizedDescription
                        return
                    }
                    
                    // If it's just invalid size, we fall through to try as raw key
                } catch {
                    // Generic error
                    print("Bundle import failed: \(error)")
                }

                // Fallback to raw key (32 bytes)
                if bundleData.count == 32 {
                    let privateKey = try P256.Signing.PrivateKey(rawRepresentation: bundleData)
                    CertificateManager.shared.importPrivateKey(privateKey)
                    keyOperationMessage = "Private key imported (new certificate generated)"
                } else {
                    // Since importIdentity throws detailed errors now, we can be more specific
                    // Re-run import to get the specific error if possible, or just default
                    // But simpler: just say it failed format checks
                    if bundleData.count > 2 && bundleData[0] == 0x30 {
                         keyOperationMessage = "Standard .p12 files are not supported. Please use ChatX509 export."
                    } else {
                        keyOperationMessage = "Invalid format. Expected identity bundle or 32-byte key."
                    }
                }
            } catch {
                keyOperationMessage = "Import failed: \(error.localizedDescription)"
            }
            
        case .failure(let error):
            keyOperationMessage = "Import failed: \(error.localizedDescription)"
        }
    }
    
    private func handleKeyExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            keyOperationMessage = "Identity exported successfully"
        case .failure(let error):
            keyOperationMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Key Document for FileExporter
struct KeyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    
    var data: Data
    
    init(data: Data) {
        self.data = data
    }
    
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - User Row View
struct UserRowView: View {
    let user: ChatUser
    @Environment(\.colorScheme) var colorScheme
    
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
                                .stroke(colorScheme == .dark ? Color(red: 0.1, green: 0.1, blue: 0.2) : Color.white, lineWidth: 3)
                        )
                        .offset(x: 18, y: 18)
                }
            }
            
            // User info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(userDisplayTitle)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
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
                                colorScheme == .dark ?
                                AnyShapeStyle(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)) :
                                AnyShapeStyle(Color.blue)
                            )
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
        .contentShape(Rectangle())
    }
    
    private var userDisplayTitle: String {
        // Extract Organization from certificateSubject "..., O=Org, ..."
        var orgDisplay = ""
        if let range = user.certificateSubject.range(of: "O=([^,]+)", options: .regularExpression) {
            let orgPart = String(user.certificateSubject[range])
            // Remove "O=" prefix
            let orgName = orgPart.dropFirst(2)
            orgDisplay = " (\(orgName))"
        }
        
        let sameNameUsers = ChatUserStore.shared.users.filter { $0.name == user.name }
        if sameNameUsers.count > 1 {
            if let serial = user.serialNumber {
                let serialHex = serial.prefix(4).map { String(format: "%02X", $0) }.joined()
                return "\(user.name)\(orgDisplay) (#\(serialHex))"
            }
        }
        return "\(user.name)\(orgDisplay)"
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

// MARK: - Own Certificate Sheet

struct OwnCertificateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let certificate: AuthenticationFramework_Certificate
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        AnyNavigationStack {
            ZStack {
                if colorScheme == .dark {
                    Color(red: 0.05, green: 0.05, blue: 0.12).ignoresSafeArea()
                } else {
                    Color(white: 0.95).ignoresSafeArea()
                }
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Icon
                        ZStack {
                            Circle()
                                .fill(colorScheme == .dark ?
                                     AnyShapeStyle(LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                                     AnyShapeStyle(Color.gray.opacity(0.1))
                                )
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: "person.badge.shield.checkmark.fill")
                                .font(.system(size: 36))
                                .foregroundColor(CertificateManager.shared.isExpired ? .red : .green)
                        }
                        .padding(.top, 20)
                        
                        // User Info
                        VStack(spacing: 8) {
                            Text(CertificateManager.shared.username)
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            
                            Text("Your secure identity")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        // Certificate Status
                        VStack(spacing: 16) {
                            // Valid/Expired Status
                            certificateRow(title: "Status", value: CertificateManager.shared.isExpired ? "Expired" : "Valid", isPositive: !CertificateManager.shared.isExpired)
                            
                            if let expiry = CertificateManager.shared.expirationDate {
                                certificateRow(title: "Expires", value: formatDate(expiry), isPositive: nil)
                            }
                            
                            certificateRow(title: "Type", value: CertificateManager.shared.isImportedKey ? "Imported (Permanent)" : "Auto-generated (30m)", isPositive: nil)
                            
                            // Detailed Subject Info
                            if !CertificateManager.shared.certificateSubjectDetails.isEmpty {
                                Divider().background(Color.white.opacity(0.1))
                                
                                ForEach(Array(CertificateManager.shared.certificateSubjectDetails.keys.sorted()), id: \.self) { key in
                                    if let value = CertificateManager.shared.certificateSubjectDetails[key] {
                                        certificateRow(title: key, value: value, isPositive: nil)
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                        
                        // Serial Number and Public Key
                        VStack(spacing: 16) {
                            certificateDataRow(
                                title: "Serial Number",
                                data: Data(certificate.toBeSigned.serialNumber)
                            )
                            
                            certificateDataRow(
                                title: "Public Key",
                                data: Data(certificate.toBeSigned.subjectPublicKeyInfo.subjectPublicKey.bytes)
                            )
                        }
                        .padding()
                        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                        
                        if CertificateManager.shared.isExpired {
                            Button(action: { 
                                CertificateManager.shared.generateNewIdentity()
                                dismiss()
                            }) {
                                Label("Regenerate Identity", systemImage: "arrow.clockwise.circle.fill")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 14)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }
                            .padding(.top, 10)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Your Identity")
            .navigationBarTitleDisplayMode(.inline)
            .compatToolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    private func certificateRow(title: String, value: String, isPositive: Bool?) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.gray)
            Spacer()
            HStack(spacing: 6) {
                if let positive = isPositive {
                    Image(systemName: positive ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(positive ? .green : .red)
                        .font(.caption)
                }
                Text(value)
                    .foregroundColor(.primary)
            }
        }
    }
    
    private func certificateDataRow(title: String, data: Data) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.gray)
            
            Text(data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
