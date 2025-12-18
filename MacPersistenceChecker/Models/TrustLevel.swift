import Foundation
import SwiftUI

/// Livello di fiducia assegnato a un item di persistenza
enum TrustLevel: String, Codable, Comparable, CaseIterable {
    case apple = "apple"                    // Verde - Firmato Apple
    case knownVendor = "known_vendor"       // Blu - Vendor noto, firma valida
    case signed = "signed"                  // Blu chiaro - Firmato, valido
    case unknown = "unknown"                // Grigio - Non verificabile (no executable)
    case suspicious = "suspicious"          // Giallo - Firmato ma sospetto
    case unsigned = "unsigned"              // Rosso - Non firmato

    var color: Color {
        switch self {
        case .apple:
            return .green
        case .knownVendor:
            return .blue
        case .signed:
            return Color.blue.opacity(0.7)
        case .unknown:
            return .gray
        case .suspicious:
            return .yellow
        case .unsigned:
            return .red
        }
    }

    var displayName: String {
        switch self {
        case .apple:
            return "Apple"
        case .knownVendor:
            return "Known Vendor"
        case .signed:
            return "Signed"
        case .unknown:
            return "Unknown"
        case .suspicious:
            return "Suspicious"
        case .unsigned:
            return "Unsigned"
        }
    }

    var description: String {
        switch self {
        case .apple:
            return "Signed by Apple - trusted system component"
        case .knownVendor:
            return "Signed by a known, trusted vendor"
        case .signed:
            return "Valid code signature from third party"
        case .unknown:
            return "No executable to verify - data file or config"
        case .suspicious:
            return "Signed but has suspicious characteristics"
        case .unsigned:
            return "No valid code signature - potentially dangerous"
        }
    }

    var symbolName: String {
        switch self {
        case .apple:
            return "checkmark.seal.fill"
        case .knownVendor:
            return "checkmark.shield.fill"
        case .signed:
            return "checkmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        case .suspicious:
            return "exclamationmark.triangle.fill"
        case .unsigned:
            return "xmark.shield.fill"
        }
    }

    /// Sort order (lower = more suspicious, higher = more trusted)
    var sortOrder: Int {
        switch self {
        case .unsigned: return 0
        case .suspicious: return 1
        case .unknown: return 2
        case .signed: return 3
        case .knownVendor: return 4
        case .apple: return 5
        }
    }

    static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
