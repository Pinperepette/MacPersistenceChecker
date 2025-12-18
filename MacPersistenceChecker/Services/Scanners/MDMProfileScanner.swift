import Foundation

/// Scanner per MDM Profiles
final class MDMProfileScanner: PersistenceScanner {
    let category: PersistenceCategory = .mdmProfiles
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] { [] } // MDM profiles are queried via command

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Check enrollment status
        let enrollmentInfo = await checkEnrollmentStatus()

        // If enrolled, add an item for the MDM enrollment itself
        if enrollmentInfo.isEnrolled {
            var mdmItem = PersistenceItem(
                identifier: "mdm-enrollment",
                category: .mdmProfiles,
                name: "MDM Enrollment"
            )
            mdmItem.isEnabled = true
            mdmItem.isLoaded = true

            var details: [String] = ["MDM Enrolled"]
            if enrollmentInfo.isUserApproved {
                details.append("User Approved")
            }
            if enrollmentInfo.isDEPEnrolled {
                details.append("DEP Enrolled")
            }
            mdmItem.programArguments = details

            // MDM enrollment is managed by the organization, so mark as known vendor
            mdmItem.trustLevel = .knownVendor

            items.append(mdmItem)
        }

        // Get all installed profiles
        let profiles = await listProfiles()
        items.append(contentsOf: profiles)

        return items
    }

    private func checkEnrollmentStatus() async -> MDMEnrollmentInfo {
        let output = await runCommand("/usr/bin/profiles", arguments: ["status", "-type", "enrollment"])

        return MDMEnrollmentInfo(
            isEnrolled: output.contains("MDM enrollment: Yes") || output.contains("Enrolled via DEP: Yes"),
            isUserApproved: output.contains("User Approved"),
            isDEPEnrolled: output.contains("Enrolled via DEP: Yes")
        )
    }

    private func listProfiles() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Get profiles with verbose output
        let output = await runCommand("/usr/bin/profiles", arguments: ["-C", "-v"])

        // Parse the output
        // Format varies but typically:
        // _computerlevel[n]  attribute: value
        // or profile identifier lines

        var currentProfile: ProfileInfo?
        var isInProfile = false

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // New profile section
            if trimmed.hasPrefix("_computerlevel") || trimmed.contains("attribute:") {
                // Save previous profile
                if let profile = currentProfile {
                    items.append(profileToItem(profile))
                }
                currentProfile = ProfileInfo()
                isInProfile = true
                continue
            }

            guard isInProfile, let _ = currentProfile else { continue }

            // Parse profile attributes
            if trimmed.hasPrefix("profileIdentifier:") {
                currentProfile?.identifier = extractValue(from: trimmed, key: "profileIdentifier:")
            } else if trimmed.hasPrefix("profileDisplayName:") || trimmed.hasPrefix("name:") {
                currentProfile?.displayName = extractValue(from: trimmed, key: trimmed.hasPrefix("profileDisplayName:") ? "profileDisplayName:" : "name:")
            } else if trimmed.hasPrefix("profileOrganization:") || trimmed.hasPrefix("organization:") {
                currentProfile?.organization = extractValue(from: trimmed, key: trimmed.hasPrefix("profileOrganization:") ? "profileOrganization:" : "organization:")
            } else if trimmed.hasPrefix("profileInstallDate:") || trimmed.hasPrefix("installDate:") {
                if let dateStr = extractValue(from: trimmed, key: trimmed.hasPrefix("profileInstallDate:") ? "profileInstallDate:" : "installDate:") {
                    currentProfile?.installDate = parseDate(dateStr)
                }
            } else if trimmed.hasPrefix("profileUUID:") {
                currentProfile?.uuid = extractValue(from: trimmed, key: "profileUUID:")
            } else if trimmed.hasPrefix("profileType:") {
                currentProfile?.profileType = extractValue(from: trimmed, key: "profileType:")
            }
        }

        // Don't forget the last profile
        if let profile = currentProfile {
            items.append(profileToItem(profile))
        }

        // If parsing failed, try alternative approach
        if items.isEmpty {
            items = await listProfilesAlternative()
        }

        return items
    }

    private func listProfilesAlternative() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Try using profiles show
        let output = await runCommand("/usr/bin/profiles", arguments: ["show", "-all"])

        // Simple parsing - look for profile names
        let lines = output.components(separatedBy: "\n")
        var index = 0

        for line in lines {
            if line.contains("Profile") || line.contains("profile") {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !name.contains(":") {
                    index += 1
                    var item = PersistenceItem(
                        identifier: "profile-\(index)",
                        category: .mdmProfiles,
                        name: name
                    )
                    item.isEnabled = true
                    item.trustLevel = .knownVendor // MDM profiles are typically trusted
                    items.append(item)
                }
            }
        }

        return items
    }

    private func profileToItem(_ profile: ProfileInfo) -> PersistenceItem {
        var item = PersistenceItem(
            identifier: profile.identifier ?? profile.uuid ?? UUID().uuidString,
            category: .mdmProfiles,
            name: profile.displayName ?? profile.identifier ?? "Unknown Profile"
        )

        item.isEnabled = true
        item.isLoaded = true

        // Store organization info
        if let org = profile.organization {
            item.signatureInfo = SignatureInfo(
                isSigned: true,
                isValid: true,
                isAppleSigned: false,
                isNotarized: false,
                hasHardenedRuntime: false,
                teamIdentifier: nil,
                bundleIdentifier: profile.identifier,
                commonName: nil,
                organizationName: org,
                certificateExpirationDate: nil,
                isCertificateExpired: false,
                signingAuthority: nil,
                codeDirectoryHash: nil,
                flags: nil
            )
        }

        // Store install date
        item.plistModifiedAt = profile.installDate

        // MDM profiles from organization are trusted
        item.trustLevel = .knownVendor

        // Store profile type in arguments
        if let pType = profile.profileType {
            item.programArguments = [pType]
        }

        return item
    }

    // MARK: - Helpers

    private func runCommand(_ path: String, arguments: [String]) async -> String {
        await CommandRunner.run(path, arguments: arguments, timeout: 5.0)
    }

    private func extractValue(from line: String, key: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private func parseDate(_ dateString: String) -> Date? {
        let formatters = [
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "MMM d, yyyy 'at' h:mm:ss a"
        ]

        for format in formatters {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        return nil
    }
}

// MARK: - Supporting Types

struct MDMEnrollmentInfo {
    let isEnrolled: Bool
    let isUserApproved: Bool
    let isDEPEnrolled: Bool
}

struct ProfileInfo {
    var identifier: String?
    var uuid: String?
    var displayName: String?
    var organization: String?
    var installDate: Date?
    var profileType: String?
}
