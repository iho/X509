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
    @State private var username: String = ""
    @State private var errorMessage: String?
    
    var onConnect: (() -> Void)?
    
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
                
                ScrollView {
                    VStack(spacing: 32) {
                        // Header
                        headerSection
                        
                        // Form fields
                        VStack(spacing: 20) {
                            usernameField
                        }
                        .padding(.horizontal, 24)
                        
                        // Connect button
                        connectButton
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 40)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
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
                .foregroundColor(.white)
            
            Text("Local Self-Signed Messaging")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }
    
    // MARK: - Username Field
    private var usernameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Identity", systemImage: "person.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.gray)
            
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .foregroundColor(.blue)
                    .frame(width: 24)
                
                TextField("Enter username", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)
                    .foregroundColor(Color.white)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
    }
    
    // MARK: - Connect Button
    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                Text("Start Chatting")
                    .font(.headline)
            }
            .foregroundColor(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.purple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(isFormValid ? 1.0 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.blue.opacity(0.4), radius: 12, y: 6)
        }
        .disabled(!isFormValid)
    }
    
    // MARK: - Validation
    private var isFormValid: Bool {
        !username.isEmpty
    }
    
    // MARK: - Actions
    private func connect() {
        guard !username.isEmpty else { return }
        CertificateManager.shared.startRotation(username: username)
        onConnect?()
    }
}

#Preview {
    SetupFormView(onConnect: {})
}
