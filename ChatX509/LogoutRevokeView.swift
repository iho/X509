//
//  LogoutRevokeView.swift
//  chat509
//
//  Created on 14.01.2026.
//

import SwiftUI

struct LogoutRevokeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var revokeAtCA: Bool = false
    @State private var showConfirmation: Bool = false
    
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
                
                VStack(spacing: 32) {
                    // Header
                    headerSection
                    
                    // Options
                    VStack(spacing: 24) {
                        revokeOption
                        
                        warningSection
                    }
                    .padding(.horizontal, 24)
                    
                    Spacer()
                    
                    // Action Button
                    deleteButton
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
                .padding(.top, 40)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.gray)
                }
            }
            .alert("Destroy Certificate?", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Destroy", role: .destructive) { performLogout() }
            } message: {
                Text("This action cannot be undone. You will lose access to your encrypted messages on this device.")
            }
        }
    }
    
    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
            }
            
            Text("Logout / Revoke")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text("Manage your certificate security")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }
    
    // MARK: - Components
    private var revokeOption: some View {
        Toggle(isOn: $revokeAtCA) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Revoke at CA")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("Permanently invalidate this certificate on the server")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: .red))
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
    
    private var warningSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundColor(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Certificate Destruction")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("Continuing will delete the X.509 certificate from this device storage. This process is irreversible.")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(16)
    }
    
    // MARK: - Action Button
    private var deleteButton: some View {
        Button(action: { showConfirmation = true }) {
            HStack {
                Image(systemName: "trash.fill")
                Text("Delete & Logout")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.red.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.red.opacity(0.3), radius: 8, y: 4)
        }
    }
    
    // MARK: - Actions
    private func performLogout() {
        if revokeAtCA {
            print("Revoking certificate at CA...")
            // TODO: CA revocation logic
        }
        
        print("Clearing local identity...")
        
        // Clear certificate and private key
        CertificateManager.shared.clearIdentity()
        
        // DO NOT clear chats anymore - as per user request
        
        // Notify app to return to setup screen
        NotificationCenter.default.post(name: .userDidLogout, object: nil)
        
        dismiss()
    }
}

// Notification for logout
extension Notification.Name {
    static let userDidLogout = Notification.Name("userDidLogout")
}
