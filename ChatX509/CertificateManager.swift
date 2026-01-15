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


// MARK: - Certificate Manager
final class CertificateManager: ObservableObject {
    static let shared = CertificateManager()
    
    // MARK: - Published State
    @Published private(set) var currentCertificate: AuthenticationFramework_Certificate?
    @Published private(set) var currentPrivateKey: P256.Signing.PrivateKey?
    @Published var username: String = ""
    
    private var rotationTimer: Timer?
    private let usernameKey = "chatx509_username"
    
    /// Returns true if user has enrolled (username is saved)
    var isEnrolled: Bool {
        !username.isEmpty
    }
    
    // OIDs
    private let oid_commonName: ASN1ObjectIdentifier = "2.5.4.3"
    private let oid_ecPublicKey: ASN1ObjectIdentifier = "1.2.840.10045.2.1"
    private let oid_secp256r1: ASN1ObjectIdentifier = "1.2.840.10045.3.1.7"
    private let oid_ecdsa_with_SHA256: ASN1ObjectIdentifier = "1.2.840.10045.4.3.2"
    
    private init() {
        // Load saved username on init
        if let savedUsername = UserDefaults.standard.string(forKey: usernameKey), !savedUsername.isEmpty {
            username = savedUsername
            // Auto-generate identity for saved user
            generateNewIdentity()
        }
    }
    
    func startRotation(username: String) {
        self.username = username
        // Save username for next launch
        UserDefaults.standard.set(username, forKey: usernameKey)
        
        generateNewIdentity()
        
        // Schedule rotation every 30 minutes (1800 seconds)
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.generateNewIdentity()
        }
    }
    
    func generateNewIdentity() {
        do {
            print("Generating new identity for \(username)...")
            let privateKey = P256.Signing.PrivateKey()
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
            let expiry = now.addingTimeInterval(1800) // 30 mins
            let notBefore = try AuthenticationFramework_Time.generalizedTime(makeGeneralizedTime(now))
            let notAfter = try AuthenticationFramework_Time.generalizedTime(makeGeneralizedTime(expiry))
            let validity = AuthenticationFramework_Validity(notBefore: notBefore, notAfter: notAfter)
            
            // 4. Algorithm (ECDSA SHA256)
            let sigAlg = AuthenticationFramework_AlgorithmIdentifier(algorithm: oid_ecdsa_with_SHA256, parameters: nil)
            
            // 5. To Be Signed
            // Serial Number: Random 16 bytes
            var serialBytes = [UInt8](repeating: 0, count: 16)
            let _ = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
            
            let tbs = AuthenticationFramework_Certificate_toBeSigned(
                version: .v3,
                serialNumber: ArraySlice(serialBytes),
                signature: sigAlg,
                issuer: name,
                validity: validity,
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
            
            // Hash and Sign
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
                print("New identity generated successfully. Expiry: \(expiry)")
                
                // Trigger discovery announce after identity is ready
                Task {
                    await UserDiscoveryService.shared.announceNow()
                }
            }
            
        } catch {
            print("Failed to generate identity: \(error)")
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
