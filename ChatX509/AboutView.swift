//
//  AboutView.swift
//  ChatX509
//
//  Created on 17.01.2026.
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    var body: some View {
        AnyNavigationStack {
            ZStack {
                // Background
                if colorScheme == .dark {
                    Color(red: 0.05, green: 0.05, blue: 0.12).ignoresSafeArea()
                } else {
                    Color(white: 0.95).ignoresSafeArea()
                }
                
                VStack(spacing: 32) {
                    Spacer()
                    
                    // App Icon & Name
                    VStack(spacing: 16) {
                        if let icon = UIImage(named: "AppIcon") {
                             Image(uiImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 120, height: 120)
                                .cornerRadius(24)
                                .shadow(radius: 10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        } else {
                            // Fallback Icon
                            ZStack {
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 120, height: 120)
                                    .shadow(radius: 10)
                                
                                Image(systemName: "person.badge.shield.checkmark.fill")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white)
                            }
                        }
                        
                        VStack(spacing: 8) {
                            Text("ChatX509")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            
                            Text("Version \(appVersion) (\(buildNumber))")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    // Description
                    VStack(spacing: 16) {
                        Text("Secure Peer-to-Peer Communication")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("ChatX509 uses X.509 certificates and Multicast UDP for serverless, encrypted local network messaging.")
                            .multilineTextAlignment(.center)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                    }
                    
                    Spacer()
                    
                    // Footer
                    VStack(spacing: 4) {
                        Text("Created with ❤️ by Zen Crypted")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("Copyright © 2026")
                            .font(.caption2)
                            .foregroundColor(.gray.opacity(0.6))
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AboutView()
}
