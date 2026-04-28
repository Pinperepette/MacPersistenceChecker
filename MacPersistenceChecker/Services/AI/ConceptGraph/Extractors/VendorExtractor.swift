import Foundation

/// Emits a concept for the item's signing identity:
/// - `vendor:apple` if Apple-signed.
/// - `vendor:teamID-{X}` for any developer TeamID.
/// These are the strongest concepts because they anchor on cryptographic
/// identity that's hard to forge.
struct VendorExtractor: ConceptFeatureExtractor {
    let name = "VendorExtractor"
    let version = 1

    func extract(from item: PersistenceItem) -> [ConceptSignal] {
        var out: [ConceptSignal] = []

        if item.signatureInfo?.isAppleSigned == true {
            out.append(ConceptSignal(
                conceptID: "vendor:apple",
                displayName: "Apple",
                kind: .vendor,
                signal: "isAppleSigned=true",
                attributes: ["isAppleSigned": "true"]
            ))
        }

        if let team = item.signatureInfo?.teamIdentifier, !team.isEmpty {
            let display: String
            if let org = item.signatureInfo?.organizationName, !org.isEmpty {
                display = org
            } else {
                display = "TeamID \(team)"
            }
            out.append(ConceptSignal(
                conceptID: "vendor:teamID-\(team)",
                displayName: display,
                kind: .vendor,
                signal: "teamID=\(team)",
                attributes: [
                    "teamID": team,
                    "organizationName": item.signatureInfo?.organizationName ?? ""
                ]
            ))
        }

        return out
    }
}
