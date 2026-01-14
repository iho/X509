import Foundation
import SwiftASN1

// Manually added missing OIDs from UsefulDefinitions module
// Derived from X.500 standards

// id-ds OBJECT IDENTIFIER ::= { joint-iso-itu-t ds(5) }
public let UsefulDefinitions_id_ds: ASN1ObjectIdentifier = "2.5"

// id-at OBJECT IDENTIFIER ::= { id-ds 4 }
public let UsefulDefinitions_id_at: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [4]

// id-oc OBJECT IDENTIFIER ::= { id-ds 6 }
public let UsefulDefinitions_id_oc: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [6]

// id-pr OBJECT IDENTIFIER ::= { id-ds 11 }
public let UsefulDefinitions_id_pr: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [11]

// id-mr OBJECT IDENTIFIER ::= { id-ds 13 }
public let UsefulDefinitions_id_mr: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [13]

// id-not OBJECT IDENTIFIER ::= { id-ds 17 }
public let UsefulDefinitions_id_not: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [17]

// id-nf OBJECT IDENTIFIER ::= { id-ds 15 }
public let UsefulDefinitions_id_nf: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [15]

// id-sc OBJECT IDENTIFIER ::= { id-ds 16 }
public let UsefulDefinitions_id_sc: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [16]

// id-oa OBJECT IDENTIFIER ::= { id-ds 18 }
public let UsefulDefinitions_id_oa: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [18]

// id-cat OBJECT IDENTIFIER ::= { id-ds 20 }
public let UsefulDefinitions_id_cat: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [20]

// id-avc OBJECT IDENTIFIER ::= { id-ds 21 }
public let UsefulDefinitions_id_avc: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [21]

// id-ar OBJECT IDENTIFIER ::= { id-ds 23 }
public let UsefulDefinitions_id_ar: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [23]

// id-ce OBJECT IDENTIFIER ::= { id-ds 29 }
public let UsefulDefinitions_id_ce: ASN1ObjectIdentifier = UsefulDefinitions_id_ds + [29]
