//
//  AddUserView.swift
//  chat509
//
//  Created on 24.12.2025.
//

import SwiftUI

struct AddUserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var userStore = ChatUserStore.shared
    
    @State private var userName: String = ""
    @State private var certificateSubject: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(red: 0.1, green: 0.1, blue: 0.2)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 32) {
                        // Header icon
                        headerIcon
                        
                        // Form fields
                        VStack(spacing: 20) {
                            formField(
                                title: "Display Name",
                                placeholder: "Alice",
                                icon: "person.fill",
                                text: $userName
                            )
                            
                            formField(
                                title: "Certificate Subject",
                                placeholder: "CN=alice,O=Example",
                                icon: "person.text.rectangle",
                                text: $certificateSubject
                            )
                        }
                        .padding(.horizontal, 24)
                        
                        // Error message
                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal, 24)
                        }
                        
                        // Info text
                        infoSection
                            .padding(.horizontal, 24)
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 24)
                }
            }
            .navigationTitle("Add Contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.gray)
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button(action: addUser) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Text("Add")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!isFormValid || isLoading)
                    .foregroundColor(isFormValid ? .blue : .gray)
                }
            }
        }
    }
    
    // MARK: - Header Icon
    private var headerIcon: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 100, height: 100)
                .blur(radius: 20)
            
            Image(systemName: "person.badge.plus")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
    
    // MARK: - Form Field
    private func formField(
        title: String,
        placeholder: String,
        icon: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.gray)
            
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .frame(width: 24)
                
                TextField(placeholder, text: text)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
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
    
    // MARK: - Info Section
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How it works", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            
            Text("Enter the certificate subject (CN/DN) of the person you want to chat with. Their certificate will be fetched from the CA server to establish a secure connection.")
                .font(.caption)
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Validation
    private var isFormValid: Bool {
        !userName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !certificateSubject.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    // MARK: - Actions
    private func addUser() {
        isLoading = true
        errorMessage = nil
        
        // TODO: Fetch certificate from CA server and validate
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let newUser = ChatUser(
                name: userName.trimmingCharacters(in: .whitespaces),
                certificateSubject: certificateSubject.trimmingCharacters(in: .whitespaces)
            )
            
            userStore.addUser(newUser)
            isLoading = false
            dismiss()
        }
    }
}

#Preview {
    AddUserView()
}
