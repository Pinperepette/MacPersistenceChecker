import Foundation
import SwiftUI

/// Configurazione per abilitare/disabilitare scanner specifici
/// Gli scanner "core" sono sempre abilitati, quelli "extended" sono opzionali
final class ScannerConfiguration: ObservableObject {
    static let shared = ScannerConfiguration()

    // MARK: - UserDefaults Keys

    private let extendedScannersEnabledKey = "ExtendedScannersEnabled"
    private let enabledScannersKey = "EnabledScanners"

    // MARK: - Published Properties

    /// Whether extended scanners are enabled globally
    @Published var extendedScannersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(extendedScannersEnabled, forKey: extendedScannersEnabledKey)
        }
    }

    /// Individual scanner enabled states
    @Published var enabledCategories: Set<PersistenceCategory> {
        didSet {
            let rawValues = enabledCategories.map { $0.rawValue }
            UserDefaults.standard.set(rawValues, forKey: enabledScannersKey)
        }
    }

    // MARK: - Initialization

    private init() {
        // Load from UserDefaults
        self.extendedScannersEnabled = UserDefaults.standard.bool(forKey: extendedScannersEnabledKey)

        // Load enabled categories
        if let savedCategories = UserDefaults.standard.array(forKey: enabledScannersKey) as? [String] {
            self.enabledCategories = Set(savedCategories.compactMap { PersistenceCategory(rawValue: $0) })
        } else {
            // Default: all core scanners enabled, extended scanners disabled
            self.enabledCategories = Set(PersistenceCategory.coreCategories)
        }
    }

    // MARK: - Methods

    /// Check if a specific category is enabled
    func isEnabled(_ category: PersistenceCategory) -> Bool {
        // Core categories are always enabled
        if !category.isExtendedScanner {
            return true
        }

        // Extended categories depend on global toggle and individual setting
        return extendedScannersEnabled && enabledCategories.contains(category)
    }

    /// Enable or disable a specific category
    func setEnabled(_ category: PersistenceCategory, enabled: Bool) {
        if enabled {
            enabledCategories.insert(category)
        } else {
            enabledCategories.remove(category)
        }
    }

    /// Enable all extended scanners
    func enableAllExtended() {
        extendedScannersEnabled = true
        for category in PersistenceCategory.extendedCategories {
            enabledCategories.insert(category)
        }
    }

    /// Disable all extended scanners
    func disableAllExtended() {
        extendedScannersEnabled = false
        for category in PersistenceCategory.extendedCategories {
            enabledCategories.remove(category)
        }
    }

    /// Get all currently enabled categories
    var allEnabledCategories: [PersistenceCategory] {
        var categories = PersistenceCategory.coreCategories

        if extendedScannersEnabled {
            categories.append(contentsOf: PersistenceCategory.extendedCategories.filter { enabledCategories.contains($0) })
        }

        return categories
    }

    /// Reset to defaults
    func resetToDefaults() {
        extendedScannersEnabled = false
        enabledCategories = Set(PersistenceCategory.coreCategories)
    }
}

// MARK: - SwiftUI View for Configuration

struct ScannerConfigurationView: View {
    @ObservedObject var config = ScannerConfiguration.shared

    var body: some View {
        Form {
            // Core Scanners Section
            Section {
                ForEach(PersistenceCategory.coreCategories, id: \.self) { category in
                    HStack {
                        Label(category.displayName, systemImage: category.systemImage)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            } header: {
                Text("Core Scanners (Always Enabled)")
            } footer: {
                Text("These scanners check the most common persistence mechanisms.")
            }

            // Extended Scanners Section
            Section {
                Toggle(isOn: $config.extendedScannersEnabled) {
                    Label("Enable Extended Scanners", systemImage: "plus.circle")
                }

                if config.extendedScannersEnabled {
                    ForEach(PersistenceCategory.extendedCategories, id: \.self) { category in
                        Toggle(isOn: Binding(
                            get: { config.enabledCategories.contains(category) },
                            set: { config.setEnabled(category, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(category.displayName, systemImage: category.systemImage)
                                Text(category.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Extended Scanners (Optional)")
            } footer: {
                Text("Extended scanners check additional persistence vectors. Some may require Full Disk Access.")
            }

            // Actions Section
            Section {
                Button("Enable All Extended") {
                    config.enableAllExtended()
                }

                Button("Disable All Extended") {
                    config.disableAllExtended()
                }

                Button("Reset to Defaults", role: .destructive) {
                    config.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Preview

#if DEBUG
struct ScannerConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        ScannerConfigurationView()
            .frame(width: 500, height: 700)
    }
}
#endif
