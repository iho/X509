//
//  ChatView.swift
//  chat509
//
//  Created on 24.12.2025.
//

import SwiftUI
import SwiftASN1
import UniformTypeIdentifiers
import PhotosUI
import AVFoundation

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
    
    // Attachment State
    @StateObject private var voiceRecorder = VoiceRecorder()
    @State private var isPhotoPickerPresented = false
    @State private var isFilePickerPresented = false

    @State private var selectedAttachmentData: Data?
    @State private var selectedAttachmentName: String?
    @State private var selectedAttachmentMime: String?
    
    // Image Preview State
    @State private var previewImage: UIImage?
    @State private var isPreviewingImage = false
    
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
        .compatToolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        #endif
        .onAppear {
            // Mark messages as read when opening chat
            ChatUserStore.shared.markAsRead(user)
        }
        .sheet(isPresented: $showCertificateSheet) {
            CertificateDetailSheet(user: user)
        }
        // .compatToolbarColorScheme(.dark, for: .navigationBar) // unavailable on macOS
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
             handleFileSelection(result)
        }
        .onChange(of: selectedAttachmentData) { newData in
            if newData != nil && selectedAttachmentName == nil {
                // Default logic if name not set (e.g. from photo picker)
                selectedAttachmentName = "image.jpg"
                selectedAttachmentMime = "image/jpeg"
            }
        }
        // Image Preview Modal
        .fullScreenCover(isPresented: $isPreviewingImage) {
            if let image = previewImage {
                ImagePreviewView(image: image)
            }
        }
    }
    
    // MARK: - Messages Scroll
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(messageStore.messages) { message in
                        MessageBubbleView(message: message, onImageTapped: { image in
                            self.previewImage = image
                            self.isPreviewingImage = true
                        })
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
        VStack(spacing: 0) {
            // Attachment Preview
            if let name = selectedAttachmentName {
                HStack {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button(action: clearAttachment) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom))
            }
            
            HStack(spacing: 12) {
                // Attachment button
                Menu {
                    Button(action: { isFilePickerPresented = true }) {
                        Label("File", systemImage: "doc.fill")
                    }
                    
                    Button(action: { isPhotoPickerPresented = true }) {
                        Label("Photo", systemImage: "photo.fill")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
                
                // Text field
                HStack {
                    MultiLineTextField(
                        placeholder: voiceRecorder.isRecording ? "Recording Audio..." :
                        selectedAttachmentData != nil ? "File Selected" : "Message",
                        text: $messageText,
                        focused: $isInputFocused
                    )
                    .foregroundColor(.primary)
                    //.lineLimit(1...5) // MultiLineTextField handles growing
                    .disabled(voiceRecorder.isRecording || selectedAttachmentData != nil)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                )
                
                // Send / Record button
                if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAttachmentData != nil {
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
                 } else {
                     // Voice Logic
                     HStack(spacing: 8) {
                         if voiceRecorder.isRecording {
                             Text(formatDuration(voiceRecorder.recordingTime))
                                 .font(.subheadline.monospacedDigit())
                                 .foregroundColor(.red)
                                 .transition(.move(edge: .trailing).combined(with: .opacity))
                         }
                         
                         Button(action: {
                             if voiceRecorder.isRecording {
                                 stopRecordingAndSend()
                             } else {
                                 voiceRecorder.startRecording()
                             }
                         }) {
                             Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.fill")
                                 .font(.title)
                                 .foregroundColor(voiceRecorder.isRecording ? .red : .gray)
                                 .scaleEffect(voiceRecorder.isRecording ? 1.2 : 1.0)
                                 .animation(.easeInOut(duration: 0.2), value: voiceRecorder.isRecording)
                         }
                     }
                 }
             }
             .padding(.horizontal, 12)
             .padding(.vertical, 8)
             .background(.ultraThinMaterial)
             .animation(.easeInOut(duration: 0.2), value: messageText.isEmpty)
         }
         // Photo Picker (Moved out of Menu)
         .photoPickerSheet(isPresented: $isPhotoPickerPresented, selection: $selectedAttachmentData)
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
                 // ... (unchanged)
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
         // ... (confirmation dialog unchanged)
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
         
         if selectedAttachmentData != nil {
              // Sending attachment
              messageStore.sendMessage(
                  content.isEmpty ? "Sent a file" : content,
                  attachment: selectedAttachmentData,
                  attachmentName: selectedAttachmentName,
                  attachmentMime: selectedAttachmentMime
              )
              clearAttachment()
              messageText = ""
              return
         }
         
         guard !content.isEmpty else { return }
         messageStore.sendMessage(content)
         messageText = ""
     }
     
     private func stopRecordingAndSend() {
         if let (url, duration) = voiceRecorder.stopRecording() {
             Task.detached(priority: .userInitiated) {
                 do {
                     let data = try Data(contentsOf: url)
                     let fileName = url.lastPathComponent
                     await MainActor.run {
                         messageStore.sendMessage(
                            "Voice Message (\(Int(duration))s)",
                            attachment: data,
                            attachmentName: fileName,
                            attachmentMime: "audio/m4a"
                         )
                     }
                 } catch {
                     print("Failed to read voice msg: \(error)")
                 }
             }
         }
     }
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let data = try Data(contentsOf: url)
                selectedAttachmentData = data
                selectedAttachmentName = url.lastPathComponent
                selectedAttachmentMime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            } catch {
                print("Failed to read file: \(error)")
            }
        case .failure(let error):
            print("Import failed: \(error)")
        }
    }
    
    private func clearAttachment() {
        selectedAttachmentData = nil
        selectedAttachmentName = nil
        selectedAttachmentMime = nil

    }
    
    private func scrollToBottom() {
        guard let lastMessage = messageStore.messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "00:00"
    }
}

// MARK: - Message Bubble View
struct MessageBubbleView: View {
    let message: ChatMessage
    var onImageTapped: ((UIImage) -> Void)? // Callback for image preview
    @Environment(\.colorScheme) var colorScheme
    
    @State private var loadedAttachmentData: Data?
    @State private var loadingError: String?
    @State private var isLoading = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    
    private var displayData: Data? {
        message.attachmentData ?? loadedAttachmentData
    }
    
    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }
            
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                if let mime = message.attachmentMime {
                    if let attachmentData = displayData {
                        // --- Attachment Content ---
                        if mime.hasPrefix("image/"), let uiImage = UIImage(data: attachmentData) {
                             Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 200)
                                .cornerRadius(12)
                                .onTapGesture {
                                    onImageTapped?(uiImage)
                                }
                        } else if mime.hasPrefix("audio/") {
                            // Audio Message
                            AudioMessageBubble(data: attachmentData, duration: 0, isFromMe: message.isFromMe)
                        } else {
                            // Generic File
                            // Generic File - Use ShareLink for native saving
                            Button(action: {
                                let name = message.attachmentName ?? "file"
                                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                                try? attachmentData.write(to: tempURL)
                                self.shareItems = [tempURL]
                                self.showShareSheet = true
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.fill")
                                        .font(.title)
                                        .foregroundColor(message.isFromMe ? .white : .blue)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(message.attachmentName ?? "Unknown File")
                                            .font(.headline)
                                            .foregroundColor(message.isFromMe ? .white : .primary)
                                            .lineLimit(1)
                                        
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachmentData.count), countStyle: .file))
                                            .font(.caption)
                                            .foregroundColor(message.isFromMe ? .white.opacity(0.8) : .secondary)
                                    }
                                }
                                .padding(12)
                                .background(bubbleBackground)
                            }
                            .shareSheet(isPresented: $showShareSheet, items: shareItems)
                            .buttonStyle(.plain) // Remove button styling to look like a bubble
                        }
                    } else {
                        // --- Loading / Error State ---
                        HStack(spacing: 8) {
                            if let error = loadingError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Failed to load")
                                        .font(.caption.bold())
                                    Text(error)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                
                                // Retry Button
                                Button(action: {
                                    Task { await loadAttachment() }
                                }) {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundColor(message.isFromMe ? .white : .blue)
                                }
                                
                                // Delete/Remove Button
                                Button(action: {
                                    Task { await deleteAttachment() }
                                }) {
                                    Image(systemName: "trash.fill")
                                        .foregroundColor(.red)
                                        .font(.caption)
                                }
                            } else {
                                ProgressView()
                                    .tint(message.isFromMe ? .white : .primary)
                                Text("Decrypting...")
                                    .font(.caption)
                                    .foregroundColor(message.isFromMe ? .white : .primary)
                            }
                        }
                        .padding(12)
                        .background(bubbleBackground)
                        .task {
                            if loadedAttachmentData == nil && loadingError == nil {
                                await loadAttachment()
                            }
                        }
                    }
                } else {
                    // --- Text Content ---
                    Text(message.content)
                        .font(.body)
                        .foregroundColor(message.isFromMe ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleBackground)
                }
                
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
    
    private func loadAttachment() async {
        guard !isLoading else { return }
        guard let path = message.localAttachmentPath else {
            // Check if we previously deleted it (state)
            if loadingError == "Attachment removed" { return }
            
            await MainActor.run { loadingError = "Missing file path" }
            return
        }
        
        await MainActor.run {
            isLoading = true
            loadingError = nil
        }
        
        do {
            let data = try await SecureStorageService.shared.loadEncryptedAttachment(filename: path)
            await MainActor.run {
                withAnimation {
                    self.loadedAttachmentData = data
                    self.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                print("Failed to load/decrypt attachment: \(error)")
                self.loadingError = "Decryption failed"
                self.isLoading = false
            }
        }
    }
    
    private func deleteAttachment() async {
        guard let path = message.localAttachmentPath else { return }
        
        await SecureStorageService.shared.deleteAttachment(filename: path)
        
        await MainActor.run {
            withAnimation {
                self.loadingError = "Attachment removed"
                self.isLoading = false
            }
        }
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
    
    private func shareFile(data: Data, name: String) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: tempURL)
        
        let av = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        
        // Find top controller to present
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(av, animated: true, completion: nil)
        }
    }
}

// MARK: - Audio Bubble
struct AudioMessageBubble: View {
    let data: Data
    let duration: TimeInterval
    let isFromMe: Bool
    @State private var isPlaying = false
    @State private var audioPlayer: AVAudioPlayer?
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                if isPlaying {
                    audioPlayer?.stop()
                    isPlaying = false
                } else {
                    playAudio()
                }
            }) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundColor(isFromMe ? .white : .blue)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Message")
                    .font(.headline)
                    .foregroundColor(isFromMe ? .white : .primary)
                
                Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                   .font(.caption)
                   .foregroundColor(isFromMe ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(12)
        .background(bubbleBackground)
    }
    
    private var bubbleBackground: some View {
        Group {
            if isFromMe {
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
    
    private func playAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = nil // TODO: Handle finish
            audioPlayer?.play()
            isPlaying = true
            
            // Simple timer to reset state
            Timer.scheduledTimer(withTimeInterval: audioPlayer?.duration ?? 0, repeats: false) { _ in
                isPlaying = false
            }
        } catch {
            print("Audio playback failed: \(error)")
        }
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
    AnyNavigationStack {
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
                            Text(user.certificateSubject)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        
                        // ... existing cert view ...
                        
                    }

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

// MARK: - Image Preview View
struct ImagePreviewView: View {
    let image: UIImage
    @Environment(\.dismiss) var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = value
                        }
                        .onEnded { _ in
                            withAnimation {
                                scale = 1.0
                            }
                        }
                )
            
            VStack {
                HStack {
                    // Share Button
                    // Share Button
                    Button(action: {
                        shareItems = [image]
                        showShareSheet = true
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                    }
                    .shareSheet(isPresented: $showShareSheet, items: shareItems)
                    
                    Spacer()
                    
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
}

// Helper struct for Transferable
@available(iOS 16.0, *)
struct AttachmentFile: Transferable {
    let data: Data
    let name: String
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try? file.data.write(to: tempURL)
            return SentTransferredFile(tempURL)
        }
    }
}
