//
//  CertificateManager.swift
//  chat509
//
//  Created by Chat509 on 2026-01-14.
//

import Foundation
import CryptoKit
import SwiftASN1
import Combine


// MARK: - Import Errors
enum CertificateImportError: LocalizedError {
    case invalidSize
    case invalidKeyLength(UInt32)
    case standardP12NotSupported
    case invalidFormat
    case fileAccessFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidSize:
            return "File is too small to be a valid identity bundle."
        case .invalidKeyLength(let len):
            return "Invalid key length: \(len). Expected 32 bytes."
        case .standardP12NotSupported:
            return "Standard .p12 files are not supported. Please use the 'Export Identity' feature in ChatX509 to create a compatible backup."
        case .invalidFormat:
            return "The file format is invalid or corrupted."
        case .fileAccessFailed(let reason):
            return "Failed to read file: \(reason)"
        }
    }
}

// MARK: - Certificate Manager
final class CertificateManager: ObservableObject {
    static let shared = CertificateManager()
    
    // MARK: - Published State
    @Published private(set) var currentCertificate: AuthenticationFramework_Certificate?
    @Published private(set) var currentPrivateKey: P256.Signing.PrivateKey?
    @Published var username: String = ""
    @Published private(set) var isImportedKey: Bool = false  // Tracks if key was imported (no rotation)
    @Published private(set) var expirationDate: Date?
    @Published private(set) var isExpired: Bool = false
    
    private var rotationTimer: Timer?
    private var expirationCheckTimer: Timer?
    private let usernameKey = "chatx509_username"
    private let identityKey = "chatx509_identity_bundle"
    private let isImportedKeyKey = "chatx509_is_imported"
    
    /// Returns true if user has enrolled (username is saved)
    var isEnrolled: Bool {
        !username.isEmpty
    }
    
    // OIDs
    private let oid_commonName: ASN1ObjectIdentifier = "2.5.4.3"
    private let oid_organizationName: ASN1ObjectIdentifier = "2.5.4.10"
    private let oid_organizationalUnitName: ASN1ObjectIdentifier = "2.5.4.11"
    private let oid_countryName: ASN1ObjectIdentifier = "2.5.4.6"
    private let oid_localityName: ASN1ObjectIdentifier = "2.5.4.7"
    private let oid_stateOrProvinceName: ASN1ObjectIdentifier = "2.5.4.8"
    
    private let oid_ecPublicKey: ASN1ObjectIdentifier = "1.2.840.10045.2.1"
    private let oid_secp256r1: ASN1ObjectIdentifier = "1.2.840.10045.3.1.7"
    private let oid_ecdsa_with_SHA256: ASN1ObjectIdentifier = "1.2.840.10045.4.3.2"
    
    private init() {
        // Load saved settings
        username = UserDefaults.standard.string(forKey: usernameKey) ?? ""
        isImportedKey = UserDefaults.standard.bool(forKey: isImportedKeyKey)
        
        // Attempt to load existing identity
        if let savedBundle = UserDefaults.standard.data(forKey: identityKey) {
            print("Found saved identity, loading...")
            if !loadIdentity(from: savedBundle) {
                print("Failed to load saved identity, generating new one...")
                if !username.isEmpty {
                    generateNewIdentity()
                }
            } else {
                // Identity loaded, start rotation if it's not an imported key
                if !isImportedKey && !username.isEmpty {
                    // startRotationTimer() // Disabled for stable storage
                }
            }
        } else if !username.isEmpty {
            // No identity but username exists, generate new
            generateNewIdentity()
        }
        
        startExpirationCheck()
    }
    
    private func startExpirationCheck() {
        expirationCheckTimer?.invalidate()
        expirationCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkExpiration()
        }
    }
    
    func checkExpiration() {
        guard let expirationDate = expirationDate else {
            if isExpired {
                DispatchQueue.main.async { self.isExpired = false }
            }
            return
        }
        let now = Date()
        let expired = now >= expirationDate
        if isExpired != expired {
            DispatchQueue.main.async {
                self.isExpired = expired
                if expired {
                    print("Identity has expired!")
                }
            }
        }
    }
    
    private func extractDate(from time: AuthenticationFramework_Time) -> Date? {
        do {
            var serializer = DER.Serializer()
            try serializer.serialize(time)
            let der = serializer.serializedBytes
            // GeneralizedTime tag is 24, UTCTime tag is 23
            if der.count > 2 {
                let length = Int(der[1])
                let valueBytes = der.dropFirst(2).prefix(length)
                if let dateString = String(bytes: valueBytes, encoding: .utf8) {
                    let formatter = DateFormatter()
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    if der[0] == 24 {
                        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
                    } else if der[0] == 23 {
                        formatter.dateFormat = "yyMMddHHmmss'Z'"
                    }
                    return formatter.date(from: dateString)
                }
            }
        } catch {
            print("Failed to extract date from time: \(error)")
        }
        return nil
    }
    
    /// Extract detailed subject information from certificate
    func extractSubjectDetails(from certificate: AuthenticationFramework_Certificate) -> [String: String] {
        var details: [String: String] = [:]
        
        if case .rdnSequence(let rdns) = certificate.toBeSigned.subject {
            for rdn in rdns.value {
                for atav in rdn.value {
                    if case .utf8(let str) = atav.value {
                        let value = String(str)
                        
                        switch atav.type {
                        case oid_commonName:
                            details["Common Name (CN)"] = value
                        case oid_organizationName:
                            details["Organization (O)"] = value
                        case oid_organizationalUnitName:
                            details["Organizational Unit (OU)"] = value
                        case oid_countryName:
                            details["Country (C)"] = value
                        case oid_localityName:
                            details["Locality (L)"] = value
                        case oid_stateOrProvinceName:
                            details["State (ST)"] = value
                        default:
                            break
                        }
                    }
                }
            }
        }
        
        return details
    }
    
    var certificateSubjectDetails: [String: String] {
        guard let cert = currentCertificate else { return [:] }
        return extractSubjectDetails(from: cert)
    }
    
    func startRotation(username: String) {
        self.username = username
        UserDefaults.standard.set(username, forKey: usernameKey)
        
        generateNewIdentity()
        startRotationTimer()
    }
    
    private func startRotationTimer() {
        rotationTimer?.invalidate()
        // Temporary: Disable auto-rotation to ensure that local file storage remains decryptable.
        // If we rotate, the Serial Number changes, and stored encrypted files (which expect the old Serial Number)
        // become unreadable unless we migrate them or keep old keys.
        // For MVP Secure Storage: Identity is stable.
        
        /*
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.generateNewIdentity()
        }
         */
    }
    
    // MARK: - Identity Import/Export
    
    /// Export current identity as a bundle (private key + certificate)
    /// Format: [4 bytes key length][raw private key][certificate DER]
    func exportIdentity() -> Data? {
        guard let privateKey = currentPrivateKey,
              let certificate = currentCertificate else {
            return nil
        }
        
        do {
            // Serialize certificate to DER
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            let certDer = Data(serializer.serializedBytes)
            
            let data = privateKey.rawRepresentation
            var bundle = Data()
            var keyLen = UInt32(data.count).bigEndian
            bundle.append(Data(bytes: &keyLen, count: 4))
            bundle.append(data)
            bundle.append(certDer)
            
            return bundle
        } catch {
            print("Export failed: \(error)")
            return nil
        }
    }
    
    private func saveIdentity() {
        if let bundle = exportIdentity() {
            UserDefaults.standard.set(bundle, forKey: identityKey)
            UserDefaults.standard.set(isImportedKey, forKey: isImportedKeyKey)
            print("Identity and state saved to persistence")
        }
    }
    
    private func loadIdentity(from bundle: Data) -> Bool {
        guard bundle.count > 36 else { return false }
        
        let keyLenBytes = bundle.prefix(4)
        let keyLen = keyLenBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard keyLen == 32, bundle.count > 36 else { return false }
        
        let keyData = bundle[4..<36]
        let certDer = bundle[36...]
        
        do {
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: keyData)
            let certificate = try AuthenticationFramework_Certificate(derEncoded: ArraySlice(certDer))
            
            self.currentPrivateKey = privateKey
            self.currentCertificate = certificate
            self.expirationDate = self.extractDate(from: certificate.toBeSigned.validity.notAfter)
            self.checkExpiration()
            
            return true
        } catch {
            print("Load identity failed: \(error)")
            return false
        }
    }
    
    /// Import a complete identity bundle (private key + certificate)
    /// Throws CertificateImportError on failure
    @discardableResult
    func importIdentity(_ bundle: Data) throws -> Bool {
        // Check for standard P12 magic bytes (Sequence tag 0x30 + length > 0x80)
        // This is a heuristic to detect if user is trying to import a standard PKCS#12 file
        if bundle.count > 2 && bundle[0] == 0x30 && bundle[1] == 0x82 {
            throw CertificateImportError.standardP12NotSupported
        }
        
        guard bundle.count > 36 else {
            throw CertificateImportError.invalidSize
        }
        
        // Parse key length
        let keyLenBytes = bundle.prefix(4)
        let keyLen = keyLenBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        guard keyLen == 32 else {
            throw CertificateImportError.invalidKeyLength(keyLen)
        }
        
        guard bundle.count > 36 else {
             throw CertificateImportError.invalidFormat
        }
        
        let keyData = bundle[4..<36]
        let certDer = bundle[36...]
        
        do {
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: keyData)
            let certificate = try AuthenticationFramework_Certificate(derEncoded: ArraySlice(certDer))
            
            // Set the imported identity
            DispatchQueue.main.async {
                // Stop rotation - imported identities don't rotate
                self.rotationTimer?.invalidate()
                self.rotationTimer = nil
                self.isImportedKey = true
                UserDefaults.standard.set(true, forKey: self.isImportedKeyKey)
                
                // Extract username from certificate subject
                var importedUsername = ""
                let details = self.extractSubjectDetails(from: certificate)
                if let cn = details["Common Name (CN)"] {
                    importedUsername = cn
                }
                
                if !importedUsername.isEmpty {
                    self.username = importedUsername
                    UserDefaults.standard.set(importedUsername, forKey: self.usernameKey)
                }
                
                self.currentPrivateKey = privateKey
                self.currentCertificate = certificate
                self.expirationDate = self.extractDate(from: certificate.toBeSigned.validity.notAfter)
                self.checkExpiration()
                
                // PERSIST the imported identity immediately
                self.saveIdentity()
                
                print("Imported and saved identity for \(self.username), expires: \(self.expirationDate?.description ?? "unknown")")
                
                // Trigger discovery announce after identity is ready
                Task {
                    await UserDiscoveryService.shared.restart()
                }
            }
            
            return true
        } catch {
            print("Import failed: \(error)")
            // If crypto fails, it's likely a format issue
            throw CertificateImportError.invalidFormat
        }
    }
    
    /// Import an external private key and generate a matching certificate
    /// Imported keys are NOT rotated and get 1 year validity
    func importPrivateKey(_ privateKey: P256.Signing.PrivateKey) {
        // Stop rotation timer - imported keys don't rotate
        rotationTimer?.invalidate()
        rotationTimer = nil
        isImportedKey = true
        UserDefaults.standard.set(true, forKey: isImportedKeyKey)
        
        // Generate certificate with the imported key (1 year validity)
        generateCertificate(for: privateKey, validity: 365 * 24 * 60 * 60)
        
        print("Imported external private key - rotation disabled")
    }
    
    /// Clear all identity data (for logout)
    func clearIdentity() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        expirationCheckTimer?.invalidate()
        expirationCheckTimer = nil
        
        currentCertificate = nil
        currentPrivateKey = nil
        username = ""
        isImportedKey = false
        expirationDate = nil
        isExpired = false
        
        // Clear from UserDefaults
        UserDefaults.standard.removeObject(forKey: usernameKey)
        UserDefaults.standard.removeObject(forKey: identityKey)
        UserDefaults.standard.set(false, forKey: isImportedKeyKey)
        
        print("Identity and persistence cleared")
        
        // Restart discovery to reflect offline status/change
        Task {
            await UserDiscoveryService.shared.restart()
        }
    }
    
    /// Generate new identity with fresh key (30-minute validity, auto-rotates)
    func generateNewIdentity() {
        isImportedKey = false
        let privateKey = P256.Signing.PrivateKey()
        generateCertificate(for: privateKey, validity: 1800) // 30 minutes
    }
    
    /// Generate a certificate for the given private key
    private func generateCertificate(for privateKey: P256.Signing.PrivateKey, validity: TimeInterval) {
        do {
            print("Generating certificate for \(username)...")
            let publicKey = privateKey.publicKey
            
            // 1. Create Name (CommonName = username)
            let cnType = oid_commonName
            let cnValue = InformationFramework_AttributeValueX.utf8(ASN1UTF8String(username))
            let atav = InformationFramework_AttributeTypeAndValue(type: cnType, value: cnValue)
            let rdn = InformationFramework_RelativeDistinguishedName([atav])
            let rdnSequence = InformationFramework_RDNSequence([rdn])
            let name = InformationFramework_Name.rdnSequence(rdnSequence)
            
            // 2. Create Public Key Info
            let pkDer = publicKey.x963Representation
            let pkBitString = ASN1BitString(bytes: ArraySlice(pkDer))
            
            // Parameters for P256 (secp256r1)
            var curveSerializer = DER.Serializer()
            try curveSerializer.serialize(oid_secp256r1)
            let curveOidFn = curveSerializer.serializedBytes
            let curveAny = try ASN1Any(derEncoded: curveOidFn)
            
            let pkAlg = AuthenticationFramework_AlgorithmIdentifier(
                algorithm: oid_ecPublicKey,
                parameters: curveAny
            )
            
            let spki = AuthenticationFramework_SubjectPublicKeyInfo(
                algorithm: pkAlg,
                subjectPublicKey: pkBitString
            )
            
            // 3. Validity
            let now = Date()
            let expiry = now.addingTimeInterval(validity)
            let notBefore = try AuthenticationFramework_Time.generalizedTime(makeGeneralizedTime(now))
            let notAfter = try AuthenticationFramework_Time.generalizedTime(makeGeneralizedTime(expiry))
            let certValidity = AuthenticationFramework_Validity(notBefore: notBefore, notAfter: notAfter)
            
            // 4. Algorithm (ECDSA SHA256)
            let sigAlg = AuthenticationFramework_AlgorithmIdentifier(algorithm: oid_ecdsa_with_SHA256, parameters: nil)
            
            // 5. To Be Signed
            var serialBytes = [UInt8](repeating: 0, count: 16)
            let _ = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
            
            let tbs = AuthenticationFramework_Certificate_toBeSigned(
                version: .v3,
                serialNumber: ArraySlice(serialBytes),
                signature: sigAlg,
                issuer: name,
                validity: certValidity,
                subject: name,
                subjectPublicKeyInfo: spki,
                issuerUniqueIdentifier: nil,
                subjectUniqueIdentifier: nil,
                extensions: nil
            )
            
            // 6. Sign
            var tbsSerializer = DER.Serializer()
            try tbsSerializer.serialize(tbs)
            let tbsDer = tbsSerializer.serializedBytes
            
            let signature = try privateKey.signature(for: tbsDer)
            let sigBitString = ASN1BitString(bytes: ArraySlice(signature.rawRepresentation))
            
            // 7. Assemble Certificate
            let cert = AuthenticationFramework_Certificate(
                toBeSigned: tbs,
                algorithmIdentifier: sigAlg,
                encrypted: sigBitString
            )
            
            // Update State
            DispatchQueue.main.async {
                self.currentPrivateKey = privateKey
                self.currentCertificate = cert
                self.expirationDate = expiry
                self.checkExpiration()
                
                // SAVE generated identity
                self.saveIdentity()
                
                print("Certificate generated and saved successfully. Expiry: \(expiry)")
                
                // Trigger discovery announce after identity is ready
                Task {
                    await UserDiscoveryService.shared.restart()
                }
            }
            
        } catch {
            print("Failed to generate certificate: \(error)")
        }
    }
    
    private func makeGeneralizedTime(_ date: Date) throws -> GeneralizedTime {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dateString = formatter.string(from: date)
        guard let data = dateString.data(using: .utf8) else {
            throw NSError(domain: "CertManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode date"])
        }
        // Construct DER: Tag(24) + Length + Bytes
        // Assuming length < 127 for typical timestamps
        var der = [UInt8]()
        der.append(24) // GeneralizedTime tag
        der.append(UInt8(data.count))
        der.append(contentsOf: data)
        return try GeneralizedTime(derEncoded: ArraySlice(der))
    }
}
