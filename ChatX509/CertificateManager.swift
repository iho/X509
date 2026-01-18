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
    
    // MARK: - Thread-Safe State (Locked Storage)
    private let stateLock = NSLock()
    private var locked_currentCertificate: AuthenticationFramework_Certificate?
    private var locked_currentPrivateKey: P256.Signing.PrivateKey?
    private var locked_username: String = ""
    private var locked_isImportedKey: Bool = false
    private var locked_expirationDate: Date?
    private var locked_isExpired: Bool = false
    
    // MARK: - Published State (Main Actor)
    @Published private(set) var currentCertificate: AuthenticationFramework_Certificate?
    @Published private(set) var currentPrivateKey: P256.Signing.PrivateKey?
    @Published var username: String = ""
    @Published private(set) var isImportedKey: Bool = false
    @Published private(set) var expirationDate: Date?
    @Published private(set) var isExpired: Bool = false
    
    private var rotationTimer: Timer?
    private var expirationCheckTimer: Timer?
    private let usernameKey = "chatx509_username"
    private let identityKey = "chatx509_identity_bundle"
    private let isImportedKeyKey = "chatx509_is_imported"
    
    /// Returns true if user has enrolled (username is saved)
    var isEnrolled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !locked_username.isEmpty
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
        let loadedUsername = UserDefaults.standard.string(forKey: usernameKey) ?? ""
        let loadedIsImported = UserDefaults.standard.bool(forKey: isImportedKeyKey)
        
        self.username = loadedUsername
        self.locked_username = loadedUsername
        self.isImportedKey = loadedIsImported
        self.locked_isImportedKey = loadedIsImported
        
        // Attempt to load existing identity
        if let savedBundle = UserDefaults.standard.data(forKey: identityKey) {
            print("Found saved identity, loading...")
            if !loadIdentity(from: savedBundle) {
                print("Failed to load saved identity, generating new one...")
                if !loadedUsername.isEmpty {
                    generateNewIdentity()
                }
            } else {
                // Identity loaded
            }
        } else if !loadedUsername.isEmpty {
            // No identity but username exists, generate new
            generateNewIdentity()
        }
        
        startExpirationCheck()
    }
    
    // MARK: - Thread-Safe Accessors
    
    /// Thread-safe access to identity components for background networking
    /// Returns (username, certificate, privateKey) if enrolled
    func getIdentity() -> (String, AuthenticationFramework_Certificate, P256.Signing.PrivateKey)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard let cert = locked_currentCertificate,
              let key = locked_currentPrivateKey,
              !locked_username.isEmpty else {
            return nil
        }
        return (locked_username, cert, key)
    }
    
    private func updateState(username: String? = nil,
                           certificate: AuthenticationFramework_Certificate? = nil,
                           privateKey: P256.Signing.PrivateKey? = nil,
                           isImported: Bool? = nil,
                           expiration: Date? = nil) {
        stateLock.lock()
        if let u = username { locked_username = u }
        if let c = certificate { locked_currentCertificate = c }
        if let k = privateKey { locked_currentPrivateKey = k }
        if let i = isImported { locked_isImportedKey = i }
        if let e = expiration { locked_expirationDate = e }
        
        // Capture new state for Main Actor update
        let newUsername = locked_username
        let newCert = locked_currentCertificate
        let newKey = locked_currentPrivateKey
        let newImported = locked_isImportedKey
        let newExpiration = locked_expirationDate
        stateLock.unlock()
        
        DispatchQueue.main.async {
            self.username = newUsername
            self.currentCertificate = newCert
            self.currentPrivateKey = newKey
            self.isImportedKey = newImported
            self.expirationDate = newExpiration
        }
    }
    
    private func startExpirationCheck() {
        DispatchQueue.main.async {
            self.expirationCheckTimer?.invalidate()
            self.expirationCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.checkExpiration()
            }
        }
    }
    
    func checkExpiration() {
        stateLock.lock()
        let expDate = locked_expirationDate
        let isExpiredState = locked_isExpired
        stateLock.unlock()
        
        guard let expirationDate = expDate else {
            DispatchQueue.main.async {
                if self.isExpired { self.isExpired = false }
            }
            if isExpiredState {
                stateLock.lock()
                locked_isExpired = false
                stateLock.unlock()
            }
            return
        }
        
        let now = Date()
        let expired = now >= expirationDate
        
        DispatchQueue.main.async {
            if self.isExpired != expired {
                self.isExpired = expired
                if expired {
                    print("Identity has expired!")
                }
            }
        }
        
        stateLock.lock()
        locked_isExpired = expired
        stateLock.unlock()
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
        updateState(username: username)
        UserDefaults.standard.set(username, forKey: usernameKey)
        
        generateNewIdentity()
        startRotationTimer()
    }
    
    private func startRotationTimer() {
        rotationTimer?.invalidate()
        // Temporary: Disable auto-rotation to ensure that local file storage remains decryptable.
    }
    
    // MARK: - Identity Import/Export
    
    /// Export current identity as a bundle (private key + certificate)
    /// Format: [4 bytes key length][raw private key][certificate DER]
    func exportIdentity() -> Data? {
        stateLock.lock()
        let privateKey = locked_currentPrivateKey
        let certificate = locked_currentCertificate
        stateLock.unlock()
        
        guard let privateKey = privateKey,
              let certificate = certificate else {
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
            
            self.updateState(
                username: nil, // don't overwrite if not changing
                certificate: certificate,
                privateKey: privateKey,
                isImported: nil,
                expiration: self.extractDate(from: certificate.toBeSigned.validity.notAfter)
            )
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
            
            // Extract username from certificate subject
            var importedUsername = ""
            let details = self.extractSubjectDetails(from: certificate)
            if let cn = details["Common Name (CN)"] {
                importedUsername = cn
            }
            
            // Set the imported identity
            // Update state safely
            self.updateState(
                username: importedUsername.isEmpty ? nil : importedUsername,
                certificate: certificate,
                privateKey: privateKey,
                isImported: true,
                expiration: self.extractDate(from: certificate.toBeSigned.validity.notAfter)
            )
            
            DispatchQueue.main.async {
                // Stop rotation - imported identities don't rotate
                self.rotationTimer?.invalidate()
                self.rotationTimer = nil
                UserDefaults.standard.set(true, forKey: self.isImportedKeyKey)
                
                if !importedUsername.isEmpty {
                    UserDefaults.standard.set(importedUsername, forKey: self.usernameKey)
                }
                
                self.checkExpiration()
                
                // PERSIST the imported identity immediately
                self.saveIdentity()
                
                print("Imported and saved identity for \(self.username), expires: \(self.expirationDate?.description ?? "unknown")")
                
                // Trigger full service restart
                Task {
                    await ServiceSupervisor.shared.restartAllServices()
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
        // isImportedKey updated in generateCertificate -> updateState
        UserDefaults.standard.set(true, forKey: isImportedKeyKey)
        
        // Generate certificate with the imported key (1 year validity)
        // Pass isImported: true to ensure state is set correctly
        stateLock.lock()
        let name = locked_username
        stateLock.unlock()
        generateCertificate(for: privateKey, validity: 365 * 24 * 60 * 60, isImported: true, username: name)
        
        print("Imported external private key - rotation disabled")
    }
    
    /// Clear all identity data (for logout)
    func clearIdentity() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        expirationCheckTimer?.invalidate()
        expirationCheckTimer = nil
        
        updateState(
            username: "",
            certificate: nil,
            privateKey: nil,
            isImported: false,
            expiration: nil
        )
        
        stateLock.lock()
        locked_currentCertificate = nil
        locked_currentPrivateKey = nil
        locked_username = ""
        locked_isImportedKey = false
        locked_expirationDate = nil
        locked_isExpired = false
        stateLock.unlock()
        
        DispatchQueue.main.async {
            self.currentCertificate = nil
            self.currentPrivateKey = nil
            self.username = ""
            self.isImportedKey = false
            self.expirationDate = nil
            self.isExpired = false
        }
        
        // Clear from UserDefaults
        UserDefaults.standard.removeObject(forKey: usernameKey)
        UserDefaults.standard.removeObject(forKey: identityKey)
        UserDefaults.standard.set(false, forKey: isImportedKeyKey)
        
        print("Identity and persistence cleared")
        
        // Restart services to reflect offline status
        Task {
            await ServiceSupervisor.shared.restartAllServices()
        }
    }
    
    /// Generate new identity with fresh key (30-minute validity, auto-rotates)
    func generateNewIdentity() {
        print("[CertManager] generateNewIdentity called!")
        stateLock.lock()
        let name = locked_username
        stateLock.unlock()
        
        Task.detached { [weak self] in
            // isImportedKey = false will be handled in generateCertificate
            let privateKey = P256.Signing.PrivateKey()
            self?.generateCertificate(for: privateKey, validity: 1800, isImported: false, username: name) // 30 minutes
        }
    }
    
    /// Generate a certificate for the given private key
    nonisolated private func generateCertificate(for privateKey: P256.Signing.PrivateKey, validity: TimeInterval, isImported: Bool, username: String) {
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
            self.updateState(
                certificate: cert,
                privateKey: privateKey,
                isImported: isImported,
                expiration: expiry
            )
            
            DispatchQueue.main.async {
                self.checkExpiration()
                
                // SAVE generated identity
                self.saveIdentity()
                
                print("Certificate generated and saved successfully. Expiry: \(expiry)")
                
                // Trigger full service restart
                Task {
                    await ServiceSupervisor.shared.restartAllServices()
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
