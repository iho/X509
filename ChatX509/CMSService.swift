//
//  CMSService.swift
//  ChatX509
//
//  Created on 15.01.2026.
//

import Foundation
import CryptoKit
import SwiftASN1

/// Service for CMS (Cryptographic Message Syntax) encryption and decryption
/// Uses EnvelopedData with ECDH key agreement and AES-256-GCM
actor CMSService {
    static let shared = CMSService()
    
    // OIDs for CMS
    private let oid_aes256_GCM: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 1, 46]
    private let oid_dhSinglePass_stdDH_sha256kdf: ASN1ObjectIdentifier = [1, 3, 132, 1, 11, 1]
    private let oid_ecPublicKey: ASN1ObjectIdentifier = [1, 2, 840, 10045, 2, 1]
    private let oid_data: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 1]
    private let oid_envelopedData: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 3]
    
    private init() {}
    
    // MARK: - Public API
    
    /// Encrypt data for a recipient using their public key
    /// Returns CMS EnvelopedData as DER-encoded bytes
    func encrypt(data: Data, recipientPublicKey: P256.KeyAgreement.PublicKey) throws -> Data {
        // Generate ephemeral key pair for key agreement
        let ephemeralPrivateKey = P256.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralPrivateKey.publicKey
        
        // Perform ECDH key agreement
        let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        
        // Derive AES key using HKDF
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("CMS-EnvelopedData".utf8),
            outputByteCount: 32
        )
        
        // Generate random IV (96 bits for GCM)
        var ivBytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, ivBytes.count, &ivBytes)
        let nonce = try AES.GCM.Nonce(data: Data(ivBytes))
        
        // Encrypt with AES-256-GCM
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce)
        
        // Build encrypted content (IV + ciphertext + tag)
        var encryptedContent = Data(ivBytes)
        encryptedContent.append(sealedBox.ciphertext)
        encryptedContent.append(sealedBox.tag)
        
        // Build CMS EnvelopedData structure
        let envelopedData = try buildEnvelopedData(
            ephemeralPublicKey: ephemeralPublicKey,
            encryptedContent: encryptedContent
        )
        
        // Serialize to DER
        var serializer = DER.Serializer()
        try serializer.serialize(envelopedData)
        return Data(serializer.serializedBytes)
    }
    
    /// Decrypt CMS EnvelopedData using private key
    func decrypt(envelopedData derData: Data, privateKey: P256.KeyAgreement.PrivateKey) throws -> Data {
        // Parse EnvelopedData
        let envelopedData = try CryptographicMessageSyntax_2009_EnvelopedData(derEncoded: ArraySlice(derData))
        
        // Extract originator's ephemeral public key from first RecipientInfo
        guard let recipientInfo = envelopedData.recipientInfos.value.first else {
            throw CMSError.noRecipientInfo
        }
        
        // Get ephemeral public key
        let ephemeralPublicKey = try extractEphemeralPublicKey(from: recipientInfo)
        
        // Perform ECDH key agreement
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        
        // Derive AES key using same HKDF parameters
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("CMS-EnvelopedData".utf8),
            outputByteCount: 32
        )
        
        // Extract encrypted content
        guard let encryptedOctets = envelopedData.encryptedContentInfo.encryptedContent else {
            throw CMSError.noEncryptedContent
        }
        let encryptedData = Data(encryptedOctets.bytes)
        
        // Parse IV (12 bytes) + ciphertext + tag (16 bytes)
        guard encryptedData.count > 28 else { // 12 + min 1 + 16
            throw CMSError.invalidEncryptedContent
        }
        
        let iv = encryptedData.prefix(12)
        let ciphertextAndTag = encryptedData.dropFirst(12)
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)
        
        // Decrypt with AES-256-GCM
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
        
        return plaintext
    }
    
    // MARK: - Private Helpers
    
    private func buildEnvelopedData(
        ephemeralPublicKey: P256.KeyAgreement.PublicKey,
        encryptedContent: Data
    ) throws -> CryptographicMessageSyntax_2009_EnvelopedData {
        // Build OriginatorPublicKey with ephemeral key
        let ephemeralKeyBytes = ephemeralPublicKey.x963Representation
        let originatorKey = CryptographicMessageSyntax_2009_OriginatorPublicKey(
            algorithm: CryptographicMessageSyntax_2009_AlgorithmIdentifier(
                algorithm: oid_ecPublicKey,
                parameters: nil
            ),
            publicKey: ASN1BitString(bytes: ArraySlice(ephemeralKeyBytes))
        )
        
        // Build KeyAgreeRecipientInfo
        // Note: Simplified - in practice would include actual recipient key identifiers
        let emptyRdnSequence = InformationFramework_RDNSequence([])
        let recipientEncryptedKey = CryptographicMessageSyntax_2009_RecipientEncryptedKey(
            rid: .issuerAndSerialNumber(
                CryptographicMessageSyntax_2009_IssuerAndSerialNumber(
                    issuer: CryptographicMessageSyntax_2009_Name.rdnSequence(emptyRdnSequence),
                    serialNumber: ArraySlice([0x00])
                )
            ),
            encryptedKey: ASN1OctetString(contentBytes: []) // Key is derived, not encrypted
        )
        
        let keyAgreeInfo = CryptographicMessageSyntax_2009_KeyAgreeRecipientInfo(
            version: .v3,
            originator: .originatorKey(originatorKey),
            ukm: nil,
            keyEncryptionAlgorithm: CryptographicMessageSyntax_2009_AlgorithmIdentifier(
                algorithm: oid_dhSinglePass_stdDH_sha256kdf,
                parameters: nil
            ),
            recipientEncryptedKeys: CryptographicMessageSyntax_2009_RecipientEncryptedKeys([recipientEncryptedKey])
        )
        
        let recipientInfo = CryptographicMessageSyntax_2009_RecipientInfo.kari(keyAgreeInfo)
        
        // Build EncryptedContentInfo
        let encryptedContentInfo = CryptographicMessageSyntax_2009_EncryptedContentInfo(
            contentType: oid_data,
            contentEncryptionAlgorithm: CryptographicMessageSyntax_2009_AlgorithmIdentifier(
                algorithm: oid_aes256_GCM,
                parameters: nil
            ),
            encryptedContent: ASN1OctetString(contentBytes: ArraySlice(encryptedContent))
        )
        
        // Build EnvelopedData
        return CryptographicMessageSyntax_2009_EnvelopedData(
            version: .v2,
            originatorInfo: nil,
            recipientInfos: CryptographicMessageSyntax_2009_RecipientInfos([recipientInfo]),
            encryptedContentInfo: encryptedContentInfo,
            unprotectedAttrs: nil
        )
    }
    
    private func extractEphemeralPublicKey(from recipientInfo: CryptographicMessageSyntax_2009_RecipientInfo) throws -> P256.KeyAgreement.PublicKey {
        guard case .kari(let keyAgree) = recipientInfo else {
            throw CMSError.unsupportedRecipientInfo
        }
        
        guard case .originatorKey(let originatorKey) = keyAgree.originator else {
            throw CMSError.missingOriginatorKey
        }
        
        let keyBytes = Data(originatorKey.publicKey.bytes)
        return try P256.KeyAgreement.PublicKey(x963Representation: keyBytes)
    }
}

// MARK: - Errors

enum CMSError: Error, LocalizedError {
    case noRecipientInfo
    case noEncryptedContent
    case invalidEncryptedContent
    case unsupportedRecipientInfo
    case missingOriginatorKey
    case keyDerivationFailed
    
    var errorDescription: String? {
        switch self {
        case .noRecipientInfo: return "No recipient info in EnvelopedData"
        case .noEncryptedContent: return "No encrypted content"
        case .invalidEncryptedContent: return "Invalid encrypted content format"
        case .unsupportedRecipientInfo: return "Unsupported RecipientInfo type"
        case .missingOriginatorKey: return "Missing originator key"
        case .keyDerivationFailed: return "Key derivation failed"
        }
    }
}
