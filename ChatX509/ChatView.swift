//
//  ChatView.swift
//  chat509
//
//  Created on 24.12.2025.
//

import SwiftUI

struct ChatView: View {
    let user: ChatUser
    @Environment(\.dismiss) private var dismiss
    @StateObject private var messageStore: ChatMessageStore
    @State private var messageText: String = ""
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isInputFocused: Bool
    
    init(user: ChatUser) {
        self.user = user
        _messageStore = StateObject(wrappedValue: ChatMessageStore(userId: user.id))
    }
    
    var body: some View {
        ZStack {
            // Background
            Color(red: 0.05, green: 0.05, blue: 0.12)
                .ignoresSafeArea()
            
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
                    .foregroundColor(.white)
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
                    .fill(Color.white.opacity(0.1))
            )
            
            // Send button
            if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
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
                .foregroundColor(.white)
            
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
        Button(action: { /* TODO */ }) {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundColor(.gray)
        }
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
    
    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }
            
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                
                HStack(spacing: 4) {
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
                LinearGradient(
                    colors: [Color.blue, Color.purple.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(BubbleShape(isFromMe: true))
            } else {
                Color.white.opacity(0.15)
                    .clipShape(BubbleShape(isFromMe: false))
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
