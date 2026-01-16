//
//  SecureStorageService.swift
//  ChatX509
//
//  Created on 16.01.2026.
//

import Foundation
import SwiftASN1
import CryptoKit

/// Service to handle encrypted storage of files (attachments)
/// Ensures binary data is stored as encrypted files on disk, not in UserDefaults JSON
actor SecureStorageService {
    static let shared = SecureStorageService()
    
    private let certificateManager = CertificateManager.shared
    private let cmsService = CMSService.shared
    private let fileManager = FileManager.default
    
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private var attachmentsDirectory: URL {
        documentsDirectory.appendingPathComponent("Attachments")
    }
    
    private init() {
        setupDirectories()
    }
    
    private func setupDirectories() {
        if !fileManager.fileExists(atPath: attachmentsDirectory.path) {
            try? fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - API
    
    /// Saves data encrypted with the current user's identity
    /// Returns the filename (not full path)
    func saveEncryptedAttachment(data: Data, extension: String? = nil) async throws -> String {
        guard let publicKey = await getMyPublicKey() else {
            throw StorageError.missingIdentity
        }
        
        // Encrypt data (At-Rest Encryption)
        let encryptedData = try await cmsService.encrypt(data: data, recipientPublicKey: publicKey)
        
        // Generate filename
        let ext = `extension` ?? "dat"
        let filename = "\(UUID().uuidString).\(ext).p7m" // .p7m indicates CMS encrypted
        let fileURL = attachmentsDirectory.appendingPathComponent(filename)
        
        // Write to disk
        try encryptedData.write(to: fileURL)
        
        print("[SecureStorage] Saved encrypted attachment: \(filename) (\(encryptedData.count) bytes)")
        return filename
    }
    
    /// Loads and decrypts data from a filename
    func loadEncryptedAttachment(filename: String) async throws -> Data {
        let fileURL = attachmentsDirectory.appendingPathComponent(filename)
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StorageError.fileNotFound
        }
        
        let encryptedData = try Data(contentsOf: fileURL)
        
        guard let privateKey = await getMyPrivateKey() else {
            throw StorageError.missingIdentity
        }
        
        // Decrypt
        return try await cmsService.decrypt(envelopedData: encryptedData, privateKey: privateKey)
    }
    
    /// Delete an attachment file
    func deleteAttachment(filename: String) {
        let fileURL = attachmentsDirectory.appendingPathComponent(filename)
        try? fileManager.removeItem(at: fileURL)
    }
    
    // MARK: - Helpers
    
    private func getMyPublicKey() async -> P256.KeyAgreement.PublicKey? {
        guard let cert = await MainActor.run(body: { certificateManager.currentCertificate }) else { return nil }
        do {
            let pubKeyBytes = Data(cert.toBeSigned.subjectPublicKeyInfo.subjectPublicKey.bytes)
            return try P256.KeyAgreement.PublicKey(x963Representation: pubKeyBytes)
        } catch {
            print("[SecureStorage] Failed to extract public key: \(error)")
            return nil
        }
    }
    
    private func getMyPrivateKey() async -> P256.KeyAgreement.PrivateKey? {
        guard let signingKey = await MainActor.run(body: { certificateManager.currentPrivateKey }) else { return nil }
        // Convert P256.Signing.PrivateKey to KeyAgreement.PrivateKey
        // They share the same raw representation
        do {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: signingKey.rawRepresentation)
        } catch {
            print("[SecureStorage] Failed to convert private key: \(error)")
            return nil
        }
    }
}

enum StorageError: Error {
    case missingIdentity
    case fileNotFound
    case decryptionFailed
}
