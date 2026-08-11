import Foundation

/// Hardware metadata available to the identity layer without importing display frameworks.
public struct DisplayDescriptor: Equatable, Hashable, Sendable {
    public let manufacturer: String?
    public let product: String?
    public let serialNumber: String?
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let displayID: UInt32?

    public init(
        manufacturer: String? = nil,
        product: String? = nil,
        serialNumber: String? = nil,
        vendorID: UInt32? = nil,
        productID: UInt32? = nil,
        displayID: UInt32? = nil
    ) {
        self.manufacturer = manufacturer
        self.product = product
        self.serialNumber = serialNumber
        self.vendorID = vendorID
        self.productID = productID
        self.displayID = displayID
    }
}

/// Stable key used by settings persistence.
///
/// EDID manufacturer/product/serial data is preferred. When serial data is
/// absent, normalized manufacturer/product/vendor/product identifiers are
/// combined deterministically. The runtime display ID is intentionally not
/// persisted because it can change across reconfiguration or reconnect.
/// The fallback cannot distinguish two otherwise identical displays that expose
/// no unique identifier; later enumeration code must provide a better descriptor
/// when such hardware allows it.
public struct DisplayIdentity: Codable, Equatable, Hashable, Sendable {
    public enum Basis: String, Codable, Sendable {
        case edid
        case fallback
    }

    public let value: String
    public let basis: Basis

    public init(descriptor: DisplayDescriptor) {
        let manufacturer = Self.nonEmpty(descriptor.manufacturer)
        let product = Self.nonEmpty(descriptor.product)
        let serial = Self.nonEmpty(descriptor.serialNumber)

        if let manufacturer, let product, let serial {
            value = "edid-\(Self.token(manufacturer))-\(Self.token(product))-\(Self.token(serial))"
            basis = .edid
        } else {
            let fallbackParts = [
                Self.token(manufacturer),
                Self.token(product),
                Self.hex(descriptor.vendorID),
                Self.hex(descriptor.productID)
            ]
            value = "fallback-" + fallbackParts.joined(separator: "-")
            basis = .fallback
        }
    }

    /// Namespace for all UserDefaults values belonging to this display.
    public var settingsKey: String {
        "display.\(value)"
    }

    public var minimumSettingsKey: String {
        "\(settingsKey).minimum"
    }

    public var maximumSettingsKey: String {
        "\(settingsKey).maximum"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func token(_ value: String?) -> String {
        guard let value else { return "unknown" }

        let allowed = CharacterSet.alphanumerics
        var result = ""
        var previousWasSeparator = false

        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.append(contentsOf: String(scalar).uppercased())
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let token = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return token.isEmpty ? "unknown" : token
    }

    private static func hex(_ value: UInt32?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%08X", value)
    }
}
