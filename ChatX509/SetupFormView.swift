//
//  SetupFormView.swift
//  chat509
//
//  Created on 24.12.2025.
//

import SwiftUI
import UniformTypeIdentifiers

struct SetupFormView: View {
    @StateObject private var settings = ChatSettings.shared
    @State private var showQuickGenerate = false
    @State private var showEnroll = false
    @State private var showImport = false
    @State private var quickUsername: String = ""
    @State private var isFilePickerPresented = false
    @Environment(\.colorScheme) var colorScheme
    
    var onConnect: (() -> Void)?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
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
                    Color(white: 0.95).ignoresSafeArea()
                }
                
                ScrollView {
                    VStack(spacing: 40) {
                        // Header
                        headerSection
                        
                        // Action Buttons
                        VStack(spacing: 20) {
                            // Path 1: Quick Generate
                            setupCard(
                                title: "Quick Start",
                                subtitle: "Instant temporary identity. Rotates every 30 mins.",
                                icon: "bolt.fill",
                                color: .blue,
                                action: { showQuickGenerate = true }
                            )
                            
                            // Path 2: Formal Enrollment
                            setupCard(
                                title: "Enroll New",
                                subtitle: "Formal setup with organizational details.",
                                icon: "person.badge.shield.checkmark.fill",
                                color: .purple,
                                action: { showEnroll = true }
                            )
                            
                            // Path 3: Import
                            setupCard(
                                title: "Import Identity",
                                subtitle: "Restore from a .p12 or backup file.",
                                icon: "arrow.down.doc.fill",
                                color: .orange,
                                action: { isFilePickerPresented = true }
                            )
                        }
                        .padding(.horizontal, 24)
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 40)
                }
            }
            .sheet(isPresented: $showQuickGenerate) {
                quickGenerateSheet
            }
            .sheet(isPresented: $showEnroll) {
                LoginEnrollView()
            }
            .fileImporter(
                isPresented: $isFilePickerPresented,
                allowedContentTypes: [.data, UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pem") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .onReceive(NotificationCenter.default.publisher(for: .userDidConnect)) { _ in
                // Close sheets and trigger transition to chat
                showQuickGenerate = false
                showEnroll = false
                onConnect?()
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
    
    // MARK: - Components
    
    private func setupCard(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.15))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(color)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.gray.opacity(0.5))
            }
            .padding(16)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05), lineWidth: 1)
                    )
                    .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 5, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var quickGenerateSheet: some View {
        NavigationStack {
            ZStack {
                if colorScheme == .dark {
                    Color(red: 0.1, green: 0.1, blue: 0.2).ignoresSafeArea()
                } else {
                    Color(white: 0.95).ignoresSafeArea()
                }
                
                VStack(spacing: 32) {
                    Text("Enter Nickname")
                        .font(.title.bold())
                        .foregroundColor(.primary)
                    
                    TextField("Username", text: $quickUsername)
                        .padding()
                        .background(colorScheme == .dark ? Color.white.opacity(0.1) : Color.white)
                        .cornerRadius(12)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 40)
                    
                    Button(action: performQuickStart) {
                        Text("Start Chatting")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 40)
                    .disabled(quickUsername.isEmpty)
                    
                    Spacer()
                }
                .padding(.top, 60)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showQuickGenerate = false }
                        .foregroundColor(.gray)
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .blur(radius: 20)
                
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            Text("CHAT X.509")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("Choose your identity path")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }
    
    // MARK: - Actions
    private func performQuickStart() {
        guard !quickUsername.isEmpty else { return }
        CertificateManager.shared.startRotation(username: quickUsername)
        onConnect?()
    }
    
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let data = try Data(contentsOf: url)
                do {
                    try CertificateManager.shared.importIdentity(data)
                    onConnect?()
                } catch {
                     print("Import failed with error: \(error.localizedDescription)")
                }
            } catch {
                print("File read failed: \(error)")
            }
        case .failure(let error):
            print("Import failed: \(error)")
        }
    }
}

extension Notification.Name {
    static let userDidConnect = Notification.Name("userDidConnect")
}

#Preview {
    SetupFormView(onConnect: {})
}
