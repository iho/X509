//
//  ChatSettings.swift
//  chat509
//
//  Created on 24.12.2025.
//

import Foundation
import SwiftUI
import Combine

/// Observable settings model with persistent storage
@MainActor
final class ChatSettings: ObservableObject {
    
    static let shared = ChatSettings()
    
    // MARK: - Persisted Settings (UserDefaults)
    
    @AppStorage("caServerURL") var caServerURL: String = ""
    @AppStorage("relayServerURL") var relayServerURL: String = ""
    
    // MARK: - Runtime State (not persisted - temporary for session only)
    
    /// The private key data loaded from the selected file (temporary, not saved)
    @Published var privateKeyData: Data?
    
    /// The name of the selected private key file (temporary, not saved)
    @Published var privateKeyFileName: String = ""
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Validation
    
    var isConfigured: Bool {
        !caServerURL.isEmpty &&
        !relayServerURL.isEmpty &&
        privateKeyData != nil
    }
    
    var isCAURLValid: Bool {
        URL(string: caServerURL) != nil || caServerURL.isEmpty
    }
    
    var isRelayURLValid: Bool {
        URL(string: relayServerURL) != nil || relayServerURL.isEmpty
    }
    
    // MARK: - Private Key Management
    
    /// Import a private key from an external file (kept in memory only)
    func importPrivateKey(from url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw ChatSettingsError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        let data = try Data(contentsOf: url)
        privateKeyData = data
        privateKeyFileName = url.lastPathComponent
    }
    
    /// Clear the selected private key
    func clearPrivateKey() {
        privateKeyData = nil
        privateKeyFileName = ""
    }
    
    /// Reset all settings
    func reset() {
        caServerURL = ""
        relayServerURL = ""
        clearPrivateKey()
    }
}

// MARK: - Errors

enum ChatSettingsError: LocalizedError {
    case accessDenied
    case storageUnavailable
    case invalidKeyFormat
    
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to the file was denied"
        case .storageUnavailable:
            return "Unable to access app storage"
        case .invalidKeyFormat:
            return "Invalid private key format"
        }
    }
}
