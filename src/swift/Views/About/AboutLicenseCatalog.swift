// SPDX-License-Identifier: GPL-3.0+

import Foundation

struct LicenseEntry: Identifiable, Hashable {
    let idKey: String
    var id: String { idKey }

    var localizedName: String { SakuraL10n.tr("help.license.\(idKey).name") }

    var localizedLicense: String { SakuraL10n.tr("help.license.\(idKey).license") }

    var localizedCopyright: String { SakuraL10n.tr("help.license.\(idKey).copyright") }
}

struct LicenseSection: Identifiable, Hashable {
    let titleKey: String
    let entries: [LicenseEntry]
    var id: String { titleKey }
}

enum LicenseCatalog {
    static let sections: [LicenseSection] = [
        LicenseSection(titleKey: "help.license.section.this_app", entries: [
            LicenseEntry(idKey: "sakura"),
        ]),
        LicenseSection(titleKey: "help.license.section.bundled_media", entries: [
            LicenseEntry(idKey: "cherry_backdrop"),
        ]),
        LicenseSection(titleKey: "help.license.section.playstation_core", entries: [
            LicenseEntry(idKey: "beetle_psx"),
        ]),
        LicenseSection(titleKey: "help.license.section.core_libraries", entries: [
            LicenseEntry(idKey: "zlib"),
            LicenseEntry(idKey: "libchdr"),
            LicenseEntry(idKey: "lzma_sdk"),
            LicenseEntry(idKey: "zstd_sf"),
            LicenseEntry(idKey: "miniz"),
        ]),
        LicenseSection(titleKey: "help.license.section.metal_presentation", entries: [
            LicenseEntry(idKey: "fsr1_metal"),
        ]),
        LicenseSection(titleKey: "help.license.section.bundled_neural", entries: [
            LicenseEntry(idKey: "fast_srgan_ml"),
            LicenseEntry(idKey: "real_esrgan_rrdb_ml"),
        ]),
        LicenseSection(titleKey: "help.license.section.apple_frameworks", entries: [
            LicenseEntry(idKey: "apple_libs_1"),
            LicenseEntry(idKey: "apple_libs_2"),
            LicenseEntry(idKey: "apple_libs_3"),
            LicenseEntry(idKey: "apple_libs_4"),
        ]),
    ]

    static var thirdParty: [LicenseEntry] {
        sections.flatMap { $0.entries }
    }
}
