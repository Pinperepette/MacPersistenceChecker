import Foundation

/// Informazioni sulla firma del codice di un binario
struct SignatureInfo: Codable, Equatable, Hashable {
    /// Whether the binary has any signature
    let isSigned: Bool

    /// Whether the signature is valid and intact
    let isValid: Bool

    /// Whether signed by Apple
    let isAppleSigned: Bool

    /// Whether the binary is notarized by Apple
    let isNotarized: Bool

    /// Whether the binary has hardened runtime enabled
    let hasHardenedRuntime: Bool

    /// Team identifier from the certificate
    let teamIdentifier: String?

    /// Bundle identifier if available
    let bundleIdentifier: String?

    /// Common Name from the signing certificate
    let commonName: String?

    /// Organization name from the certificate
    let organizationName: String?

    /// Certificate expiration date
    let certificateExpirationDate: Date?

    /// Whether the certificate has expired
    let isCertificateExpired: Bool

    /// Full signing authority chain (e.g., "Developer ID Application: Company (TEAM_ID)")
    let signingAuthority: String?

    /// Code Directory hash for identification
    let codeDirectoryHash: String?

    /// Additional signature flags
    let flags: SignatureFlags?

    /// Creates an unsigned SignatureInfo
    static var unsigned: SignatureInfo {
        SignatureInfo(
            isSigned: false,
            isValid: false,
            isAppleSigned: false,
            isNotarized: false,
            hasHardenedRuntime: false,
            teamIdentifier: nil,
            bundleIdentifier: nil,
            commonName: nil,
            organizationName: nil,
            certificateExpirationDate: nil,
            isCertificateExpired: false,
            signingAuthority: nil,
            codeDirectoryHash: nil,
            flags: nil
        )
    }

    /// Human-readable summary
    var summary: String {
        if !isSigned {
            return "Not signed"
        }

        var parts: [String] = []

        if isAppleSigned {
            parts.append("Apple signed")
        } else if let org = organizationName {
            parts.append("Signed by \(org)")
        } else if let cn = commonName {
            parts.append("Signed: \(cn)")
        } else {
            parts.append("Signed")
        }

        if !isValid {
            parts.append("(invalid)")
        }

        if isNotarized {
            parts.append("Notarized")
        }

        if isCertificateExpired {
            parts.append("(expired cert)")
        }

        return parts.joined(separator: " - ")
    }
}

/// Additional flags from code signature
struct SignatureFlags: Codable, Equatable, Hashable {
    /// Library validation is enforced
    let hasLibraryValidation: Bool

    /// Runtime version is specified
    let hasRuntimeVersion: Bool

    /// Binary has restricted entitlements
    let isRestricted: Bool

    /// Kill process if signature becomes invalid
    let killOnInvalidSignature: Bool

    static var empty: SignatureFlags {
        SignatureFlags(
            hasLibraryValidation: false,
            hasRuntimeVersion: false,
            isRestricted: false,
            killOnInvalidSignature: false
        )
    }
}
