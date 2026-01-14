import Foundation
import SwiftASN1

// Aliases for missing types
@usableFromInline typealias PKIX1Explicit88_Attribute = PKCS_10_Attribute
public let PKIX1Explicit88_id_at = UsefulDefinitions_id_at
@usableFromInline typealias PKIX1Implicit_2009_GeneralNames = PKIX1Implicit88_GeneralNames
@usableFromInline typealias PKIX1Explicit88_AttributeType = InformationFramework_AttributeType
@usableFromInline typealias PKIX1Explicit88_DistinguishedName = InformationFramework_DistinguishedName
@usableFromInline typealias PKIX1Explicit88_DirectoryString = SelectedAttributeTypes_DirectoryString

@usableFromInline typealias DirectoryAbstractService_ServiceControlOptions = ASN1BitString
@usableFromInline typealias DirectoryAbstractService_SearchControlOptions = ASN1BitString
@usableFromInline typealias DirectoryAbstractService_HierarchySelections = ASN1BitString
@usableFromInline typealias DirectoryAbstractService_FamilyGrouping = ASN1BitString
@usableFromInline typealias DirectoryAbstractService_FamilyReturn = ASN1BitString

// ORAddress Dependencies (missing files)
@usableFromInline struct PKIX1Explicit88_BuiltInStandardAttributes: DERParseable, DERSerializable, Sendable {
    @inlinable static var defaultIdentifier: ASN1Identifier { .sequence }
    @usableFromInline var value: ASN1Any
    @inlinable init(derEncoded: inout ASN1NodeCollection.Iterator) throws {
        guard let node = derEncoded.next() else { throw ASN1Error.invalidASN1Object(reason: "No node") }
        self.value = ASN1Any(derEncoded: node)
    }
    @inlinable init(derEncoded: ASN1Node) throws {
        self.value = ASN1Any(derEncoded: derEncoded)
    }
    @inlinable func serialize(into coder: inout DER.Serializer) throws {
        try coder.serialize(value)
    }
}
@usableFromInline struct PKIX1Explicit88_BuiltInDomainDefinedAttributes: DERParseable, DERSerializable, Sendable {
    @inlinable static var defaultIdentifier: ASN1Identifier { .sequence }
    @usableFromInline var value: ASN1Any
    @inlinable init(derEncoded: inout ASN1NodeCollection.Iterator) throws {
        guard let node = derEncoded.next() else { throw ASN1Error.invalidASN1Object(reason: "No node") }
        self.value = ASN1Any(derEncoded: node)
    }
    @inlinable init(derEncoded: ASN1Node) throws {
        self.value = ASN1Any(derEncoded: derEncoded)
    }
    @inlinable func serialize(into coder: inout DER.Serializer) throws {
        try coder.serialize(value)
    }
}
@usableFromInline struct PKIX1Explicit88_ExtensionAttributes: DERParseable, DERSerializable, Sendable {
    @inlinable static var defaultIdentifier: ASN1Identifier { .sequence }
    @usableFromInline var value: ASN1Any
    @inlinable init(derEncoded: inout ASN1NodeCollection.Iterator) throws {
        guard let node = derEncoded.next() else { throw ASN1Error.invalidASN1Object(reason: "No node") }
        self.value = ASN1Any(derEncoded: node)
    }
    @inlinable init(derEncoded: ASN1Node) throws {
        self.value = ASN1Any(derEncoded: derEncoded)
    }
    @inlinable func serialize(into coder: inout DER.Serializer) throws {
        try coder.serialize(value)
    }
}

// PKIX OID roots
public let PKIX1Explicit88_id_pkix: ASN1ObjectIdentifier = "1.3.6.1.5.5.7"
public let PKIX1Explicit88_id_pe = PKIX1Explicit88_id_pkix + [1]
public let PKIX1Explicit88_id_qt = PKIX1Explicit88_id_pkix + [2]
public let PKIX1Explicit88_id_kp = PKIX1Explicit88_id_pkix + [3]
public let PKIX1Explicit88_id_ad = PKIX1Explicit88_id_pkix + [48]
