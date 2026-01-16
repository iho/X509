//
//  ChatView.swift
//  chat509
//
//  Created on 24.12.2025.
//

import SwiftUI
import SwiftASN1

struct ChatView: View {
    let user: ChatUser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var messageStore: ChatMessageStore
    @State private var messageText: String = ""
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showDeleteConfirmation = false
    @State private var showCertificateSheet = false
    @FocusState private var isInputFocused: Bool
    
    init(user: ChatUser) {
        self.user = user
        _messageStore = StateObject(wrappedValue: ChatMessageStore(userId: user.id, recipientName: user.name))
    }
    
    var body: some View {
        ZStack {
            // Background
            // Background
            if colorScheme == .dark {
                Color(red: 0.05, green: 0.05, blue: 0.12)
                    .ignoresSafeArea()
            } else {
                Color(white: 0.95) // White-gray
                    .ignoresSafeArea()
            }
            
            VStack(spacing: 0) {
                // Messages
                messagesScrollView
                
                // Input bar
                messageInputBar
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                backButton
            }
            ToolbarItem(placement: .principal) {
                userHeader
            }
            ToolbarItem(placement: .primaryAction) {
                moreButton
            }
        }
        #if os(macOS)
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        #endif
        .onAppear {
            // Mark messages as read when opening chat
            ChatUserStore.shared.markAsRead(user)
        }
        .sheet(isPresented: $showCertificateSheet) {
            CertificateDetailSheet(user: user)
        }
        // .toolbarColorScheme(.dark, for: .navigationBar) // unavailable on macOS
    }
    
    // MARK: - Messages Scroll
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(messageStore.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .onAppear {
                scrollProxy = proxy
                scrollToBottom()
            }
            .onChange(of: messageStore.messages.count) { _ in
                scrollToBottom()
            }
        }
    }
    
    // MARK: - Message Input
    private var messageInputBar: some View {
        HStack(spacing: 12) {
            // Attachment button
            Button(action: { /* TODO */ }) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundColor(.gray)
            }
            
            // Text field
            HStack {
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundColor(.primary)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                
                if messageText.isEmpty {
                    Button(action: { /* TODO: Voice */ }) {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
            )
            
            // Send button
            if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(
                            colorScheme == .dark ?
                            AnyShapeStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                            AnyShapeStyle(Color.blue)
                        )
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .animation(.easeInOut(duration: 0.2), value: messageText.isEmpty)
    }
    
    // MARK: - Toolbar Items
    private var backButton: some View {
        Button(action: { dismiss() }) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .foregroundColor(.blue)
        }
    }
    
    private var userHeader: some View {
        VStack(spacing: 2) {
            Text(user.name)
                .font(.headline)
                .foregroundColor(.primary)
            
            HStack(spacing: 4) {
                Circle()
                    .fill(user.isOnline ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(user.isOnline ? "Online" : "Offline")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
    
    private var moreButton: some View {
        Menu {
            Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                Label("Delete Chat", systemImage: "trash")
            }
            
            Button(action: { showCertificateSheet = true }) {
                Label("View Certificate", systemImage: "checkmark.shield")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundColor(.gray)
        }
        .confirmationDialog("Delete this chat?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Chat", role: .destructive) {
                deleteChat()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \(user.name) from your contacts and delete all messages.")
        }
    }
    
    private func deleteChat() {
        ChatUserStore.shared.removeUser(user)
        dismiss()
    }
    
    // MARK: - Actions
    private func sendMessage() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        
        messageStore.sendMessage(content)
        messageText = ""
    }
    
    private func scrollToBottom() {
        guard let lastMessage = messageStore.messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}

// MARK: - Message Bubble View
struct MessageBubbleView: View {
    let message: ChatMessage
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }
            
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .foregroundColor(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                
                HStack(spacing: 4) {
                    // Encryption indicator
                    if message.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    
                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    if message.isFromMe {
                        Image(systemName: message.isDelivered ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundColor(message.isDelivered ? .blue : .gray)
                    }
                }
                .padding(.horizontal, 4)
            }
            
            if !message.isFromMe { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }
    
    private var bubbleBackground: some View {
        Group {
            if message.isFromMe {
                if colorScheme == .dark {
                    LinearGradient(
                        colors: [Color.blue, Color.purple.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(BubbleShape(isFromMe: true))
                } else {
                    Color.blue
                        .clipShape(BubbleShape(isFromMe: true))
                }
            } else {
                (colorScheme == .dark ? Color.white.opacity(0.15) : Color.white)
                    .clipShape(BubbleShape(isFromMe: false))
                    .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Bubble Shape
struct BubbleShape: Shape {
    let isFromMe: Bool
    
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let tailSize: CGFloat = 6
        
        var path = Path()
        
        if isFromMe {
            // Sent message - tail on right
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius + tailSize, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            // Tail
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius - tailSize, y: rect.maxY - tailSize),
                control: CGPoint(x: rect.maxX - radius, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY - tailSize))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - radius - tailSize),
                control: CGPoint(x: rect.minX, y: rect.maxY - tailSize)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        } else {
            // Received message - tail on left
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius - tailSize))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY - tailSize),
                control: CGPoint(x: rect.maxX, y: rect.maxY - tailSize)
            )
            path.addLine(to: CGPoint(x: rect.minX + radius + tailSize, y: rect.maxY - tailSize))
            // Tail
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius - tailSize, y: rect.maxY),
                control: CGPoint(x: rect.minX + radius, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }
        
        path.closeSubpath()
        return path
    }
}

#Preview {
    NavigationStack {
        ChatView(user: ChatUser(
            name: "Alice",
            certificateSubject: "CN=alice",
            isOnline: true
        ))
    }
}

// MARK: - Certificate Detail Sheet

struct CertificateDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    let user: ChatUser
    
    var body: some View {
        NavigationStack {
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
                                     AnyShapeStyle(LinearGradient(colors: [.green.opacity(0.3), .blue.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                                     AnyShapeStyle(Color.green.opacity(0.1))
                                )
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 36))
                                .foregroundColor(.green)
                        }
                        .padding(.top, 20)
                        
                        // User Info
                        VStack(spacing: 8) {
                            Text(user.name)
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            
                            Text(user.certificateSubject)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        
                        // Certificate Status
                        VStack(spacing: 16) {
                            certificateRow(title: "Status", value: user.certificateData != nil ? "Valid" : "Not Available", isPositive: user.certificateData != nil)
                            
                            certificateRow(title: "Encryption", value: user.certificateData != nil ? "Ready" : "Not Available", isPositive: user.certificateData != nil)
                            
                            if user.isDiscovered {
                                certificateRow(title: "Discovery", value: "Auto-discovered", isPositive: true)
                            }
                            
                            if let lastSeen = user.lastSeen {
                                certificateRow(title: "Last Seen", value: formatDate(lastSeen), isPositive: nil)
                            }
                        }
                        .padding()
                        .padding()
                        .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                        
                        // Serial Number and Public Key
                        if let certData = user.certificateData {
                            VStack(spacing: 16) {
                                certificateDataRow(
                                    title: "Serial Number",
                                    data: extractSerialNumber(from: certData)
                                )
                                
                                certificateDataRow(
                                    title: "Public Key",
                                    data: extractPublicKey(from: certData)
                                )
                            }
                            .padding()
                            .padding()
                            .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func extractSerialNumber(from certData: Data) -> Data {
        // Parse X.509 certificate to extract serial number
        do {
            let certificate = try AuthenticationFramework_Certificate(derEncoded: ArraySlice(certData))
            let serialBytes = Array(certificate.toBeSigned.serialNumber)
            return Data(serialBytes.prefix(16))
        } catch {
            return Data(certData.prefix(16))
        }
    }
    
    private func extractPublicKey(from certData: Data) -> Data {
        // Parse X.509 certificate to extract public key
        do {
            let certificate = try AuthenticationFramework_Certificate(derEncoded: ArraySlice(certData))
            let pubKeyBytes = certificate.toBeSigned.subjectPublicKeyInfo.subjectPublicKey.bytes
            return Data(pubKeyBytes.prefix(16))
        } catch {
            return Data(certData.suffix(16))
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
