//
//  LoginEnrollView.swift
//  chat509
//
//  Created on 14.01.2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct LoginEnrollView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: LoginMode = .loadFromFile
    @State private var organizationalUnit: String = ""
    @Environment(\.colorScheme) var colorScheme
    @State private var commonName: String = ""
    @State private var isFilePickerPresented: Bool = false
    @State private var selectedFileName: String?
    @State private var errorMessage: String?
    
    enum LoginMode {
        case loadFromFile
        case createNew
    }
    
    var body: some View {
        AnyNavigationStack {
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
                    VStack(spacing: 32) {
                        // Header
                        headerSection
                        
                        // Mode Selection
                        modeSelection
                        
                        // Content
                        VStack(spacing: 24) {
                            if mode == .loadFromFile {
                                loadFromFileSection
                            } else {
                                createNewSection
                            }
                        }
                        .padding(.horizontal, 24)
                        .animation(.easeInOut, value: mode)
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 40)
                }
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
            .fileImporter(
                isPresented: $isFilePickerPresented,
                allowedContentTypes: [.data, .text, UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pem") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
        }
    }
    
    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 12) {
            Text("Login / Enroll")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("Access your secure identity")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Mode Selection
    private var modeSelection: some View {
        HStack(spacing: 0) {
            modeButton(title: "Load Existing", mode: .loadFromFile)
            modeButton(title: "Create New", mode: .createNew)
        }
        .background(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
        .clipShape(Capsule())
        .padding(.horizontal, 24)
    }
    
    private func modeButton(title: String, mode: LoginMode) -> some View {
        Button(action: { self.mode = mode }) {
            Text(title)
                .font(.headline)
                .foregroundColor(self.mode == mode ? .white : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.vertical, 12)
                .background(
                    Group {
                        if self.mode == mode {
                            if colorScheme == .dark {
                                LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                            } else {
                                Color.blue
                            }
                        } else {
                            Color.clear
                        }
                    }
                )
                .clipShape(Capsule())
        }
    }
    
    // MARK: - Load From File
    private var loadFromFileSection: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Client X.509 Certificate", systemImage: "doc.text.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.gray)
                
                Button(action: { isFilePickerPresented = true }) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.orange)
                        
                        Text(selectedFileName ?? "Select certificate file...")
                            .foregroundColor(selectedFileName != nil ? .primary : .gray)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        Text("Load")
                            .font(.callout.weight(.medium))
                            .foregroundColor(.blue)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), lineWidth: 1)
                            )
                    )
                }
            }
            
            Button(action: performLoad) {
                Text("Load Certificate")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Group {
                            if colorScheme == .dark {
                                LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                            } else {
                                Color.blue
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.blue.opacity(0.3), radius: 8, y: 4)
            }
            .disabled(selectedFileName == nil)
            .opacity(selectedFileName == nil ? 0.6 : 1)
        }
    }
    
    // MARK: - Create New
    private var createNewSection: some View {
        VStack(spacing: 24) {
            inputField(title: "Organizational Unit", placeholder: "e.g. Engineering", text: $organizationalUnit, icon: "building.2.fill")
            
            inputField(title: "Common Name", placeholder: "e.g. John Doe", text: $commonName, icon: "person.text.rectangle.fill")
            
            Button(action: performEnroll) {
                Text("Enroll New Certificate")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Group {
                            if colorScheme == .dark {
                                LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                            } else {
                                Color.blue
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.blue.opacity(0.3), radius: 8, y: 4)
            }
            .disabled(organizationalUnit.isEmpty || commonName.isEmpty)
            .opacity((organizationalUnit.isEmpty || commonName.isEmpty) ? 0.6 : 1)
        }
    }
    
    private func inputField(title: String, placeholder: String, text: Binding<String>, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.gray)
            
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding()
                .foregroundColor(.primary)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), lineWidth: 1)
                        )
                )
        }
    }
    
    // MARK: - Actions
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                 errorMessage = "Failed to access file"
                 return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            selectedFileName = url.lastPathComponent
            
            // Auto-load for better UX
            do {
                let data = try Data(contentsOf: url)
                do {
                    try CertificateManager.shared.importIdentity(data)
                    NotificationCenter.default.post(name: .userDidConnect, object: nil)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = "Failed to read file: \(error.localizedDescription)"
            }
            
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
    
    private func performLoad() {
        // Handled by handleFileSelection now
        if selectedFileName != nil && errorMessage == nil {
             dismiss()
        }
    }
    
    private func performEnroll() {
        print("Enrolling: OU=\(organizationalUnit), CN=\(commonName)")
        CertificateManager.shared.startRotation(username: commonName)
        
        // Trigger immediate discovery announce
        Task {
            await UserDiscoveryService.shared.announceNow()
        }
        
        NotificationCenter.default.post(name: .userDidConnect, object: nil)
        dismiss()
    }
}

#Preview {
    LoginEnrollView()
}
