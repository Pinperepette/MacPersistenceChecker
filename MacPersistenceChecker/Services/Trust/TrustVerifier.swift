import Foundation

/// Orchestratore per la verifica del trust level di un item
actor TrustVerifier {
    private let codeSignatureVerifier: CodeSignatureVerifier
    private let knownVendors: KnownVendorsDatabase

    init() {
        self.codeSignatureVerifier = CodeSignatureVerifier()
        self.knownVendors = KnownVendorsDatabase.shared
    }

    /// Verifica e assegna il trust level a un item
    func verify(_ item: PersistenceItem) async -> PersistenceItem {
        var verifiedItem = item

        // Get the binary path to verify
        guard let binaryPath = item.effectiveExecutablePath else {
            // No executable to verify - mark as unknown, not unsigned
            verifiedItem.trustLevel = .unknown
            verifiedItem.signatureInfo = nil
            return verifiedItem
        }

        // Check if it's actually a Mach-O binary (not just a data file)
        if !isMachOBinary(binaryPath) {
            verifiedItem.trustLevel = .unknown
            verifiedItem.signatureInfo = nil
            return verifiedItem
        }

        // Verify code signature
        let signatureInfo = await codeSignatureVerifier.verify(binaryPath)
        verifiedItem.signatureInfo = signatureInfo

        // Determine trust level based on signature and other factors
        verifiedItem.trustLevel = determineTrustLevel(
            signatureInfo: signatureInfo,
            item: item
        )

        return verifiedItem
    }

    /// Determina il trust level basandosi sulla firma e altri fattori
    private func determineTrustLevel(
        signatureInfo: SignatureInfo,
        item: PersistenceItem
    ) -> TrustLevel {

        // Not signed -> RED
        if !signatureInfo.isSigned {
            return .unsigned
        }

        // Apple signed -> GREEN
        if signatureInfo.isAppleSigned {
            return .apple
        }

        // Signed but invalid -> RED
        if !signatureInfo.isValid {
            return .unsigned
        }

        // Certificate expired -> YELLOW
        if signatureInfo.isCertificateExpired {
            return .suspicious
        }

        // Check for suspicious paths
        if isSuspiciousPath(item) {
            return .suspicious
        }

        // Known vendor with valid signature -> BLUE
        if let teamId = signatureInfo.teamIdentifier,
           knownVendors.isKnownVendor(teamId: teamId) {
            return .knownVendor
        }

        // Notarized with hardened runtime -> BLUE
        if signatureInfo.isNotarized && signatureInfo.hasHardenedRuntime {
            return .knownVendor
        }

        // Just notarized -> lighter BLUE
        if signatureInfo.isNotarized {
            return .signed
        }

        // Signed but not notarized and not known -> YELLOW
        return .suspicious
    }

    /// Check if the item's path is suspicious
    private func isSuspiciousPath(_ item: PersistenceItem) -> Bool {
        let pathsToCheck = [
            item.plistPath?.path,
            item.executablePath?.path
        ].compactMap { $0 }

        let suspiciousPatterns = [
            "/tmp/",
            "/var/tmp/",
            "/Users/Shared/",
            "/private/tmp/",
            "/Downloads/",
            "/.hidden",
            "/..",
            "/Caches/",
            "/Temp/"
        ]

        for path in pathsToCheck {
            let lowercasePath = path.lowercased()
            for pattern in suspiciousPatterns {
                if lowercasePath.contains(pattern.lowercased()) {
                    return true
                }
            }
        }

        // Check for unusual characters in path
        for path in pathsToCheck {
            if path.contains("..") || path.contains("\u{00}") {
                return true
            }
        }

        return false
    }

    /// Check if file is a Mach-O binary by reading magic bytes
    private func isMachOBinary(_ url: URL) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? fileHandle.close() }

        guard let data = try? fileHandle.read(upToCount: 4), data.count >= 4 else {
            return false
        }

        // Mach-O magic numbers
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        // MH_MAGIC (32-bit)
        // MH_MAGIC_64 (64-bit)
        // MH_CIGAM (32-bit, byte swapped)
        // MH_CIGAM_64 (64-bit, byte swapped)
        // FAT_MAGIC (universal binary)
        // FAT_CIGAM (universal binary, byte swapped)
        let machOMagics: [UInt32] = [
            0xFEEDFACE,  // MH_MAGIC
            0xFEEDFACF,  // MH_MAGIC_64
            0xCEFAEDFE,  // MH_CIGAM
            0xCFFAEDFE,  // MH_CIGAM_64
            0xCAFEBABE,  // FAT_MAGIC
            0xBEBAFECA   // FAT_CIGAM
        ]

        // Also check for scripts (#!)
        if data[0] == 0x23 && data[1] == 0x21 {  // "#!"
            return true  // Shell script, can be signed
        }

        return machOMagics.contains(magic)
    }
}

// MARK: - Batch Verification

extension TrustVerifier {
    /// Verify multiple items concurrently
    func verifyBatch(_ items: [PersistenceItem]) async -> [PersistenceItem] {
        await withTaskGroup(of: PersistenceItem.self) { group in
            for item in items {
                group.addTask {
                    await self.verify(item)
                }
            }

            var results: [PersistenceItem] = []
            for await item in group {
                results.append(item)
            }
            return results
        }
    }
}
