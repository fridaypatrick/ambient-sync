import Foundation

public enum DisplaySupportStatus: String, Equatable, Sendable {
    case builtIn
    case verifiedExternal
    case writeOnlyExternal
    case degradedExternal
    case degradedWriteOnlyExternal
    case unsupportedExternal

    public var isExternal: Bool {
        self != .builtIn
    }

    public var isWriteOnly: Bool {
        self == .writeOnlyExternal || self == .degradedWriteOnlyExternal
    }

    public var isDegraded: Bool {
        self == .degradedExternal || self == .degradedWriteOnlyExternal
    }

    public var userFacingLabel: String {
        switch self {
        case .builtIn:
            return "Built-in display"
        case .verifiedExternal:
            return "External display · brightness control verified"
        case .writeOnlyExternal:
            return "External display · brightness control unverified (write-only)"
        case .degradedExternal:
            return "External display · brightness control degraded"
        case .degradedWriteOnlyExternal:
            return "External display · brightness control degraded · unverified (write-only)"
        case .unsupportedExternal:
            return "External display · unsupported for brightness control"
        }
    }
}

public struct ExternalDisplayCapability: Equatable, Hashable, Sendable {
    public let maximum: UInt16
    public let isWriteOnly: Bool

    public init(maximum: UInt16, isWriteOnly: Bool) {
        self.maximum = max(maximum, 1)
        self.isWriteOnly = isWriteOnly
    }

    public static func verified(maximum: UInt16) -> Self {
        Self(maximum: maximum, isWriteOnly: false)
    }

    public static func writeOnlyAssumed(maximum: UInt16) -> Self {
        Self(maximum: maximum, isWriteOnly: true)
    }
}

/// Runtime display record. `displayID` is intentionally runtime-only and is
/// never used by `DisplayIdentity` for settings persistence.
public struct DisplayRecord: Equatable, Hashable, Sendable {
    public let displayID: UInt32
    public let name: String
    public let descriptor: DisplayDescriptor
    public let identity: DisplayIdentity
    public let isBuiltIn: Bool

    public init(
        displayID: UInt32,
        name: String,
        descriptor: DisplayDescriptor,
        isBuiltIn: Bool
    ) {
        self.displayID = displayID
        self.name = name
        self.descriptor = descriptor
        self.identity = DisplayIdentity(descriptor: descriptor)
        self.isBuiltIn = isBuiltIn
    }
}

public struct DisplayState: Equatable, Hashable, Sendable {
    public let record: DisplayRecord
    public let support: DisplaySupportStatus
    public let capability: ExternalDisplayCapability?

    public init(
        record: DisplayRecord,
        support: DisplaySupportStatus,
        capability: ExternalDisplayCapability? = nil
    ) {
        self.record = record
        self.support = support
        self.capability = capability
    }
}

public struct DisplaySnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let displays: [DisplayState]
    public let builtIn: DisplayRecord?

    public init(
        generation: UInt64,
        displays: [DisplayState],
        builtIn: DisplayRecord?
    ) {
        self.generation = generation
        self.displays = displays
        self.builtIn = builtIn
    }

    public static let empty = DisplaySnapshot(generation: 0, displays: [], builtIn: nil)
}

public protocol DisplayEnumerator: Sendable {
    func enumerate() async -> [DisplayRecord]
}

public protocol BuiltInBrightnessSource: Sendable {
    func readBrightness(for displayID: UInt32) async -> Double?
}

public protocol ExternalBrightnessSink: Sendable {
    func writeBrightness(_ percent: Int) async -> Bool
    func invalidate() async
}

public struct ExternalDisplayBinding: Sendable {
    public let record: DisplayRecord
    public let sink: any ExternalBrightnessSink
    public let capability: ExternalDisplayCapability

    public init(
        record: DisplayRecord,
        sink: any ExternalBrightnessSink,
        capability: ExternalDisplayCapability = .verified(maximum: 100)
    ) {
        self.record = record
        self.sink = sink
        self.capability = capability
    }
}

public protocol ExternalDisplayTransportProvider: Sendable {
    func rebuild(for displays: [DisplayRecord]) async -> [ExternalDisplayBinding]
    func invalidate() async
    func updateAssumedMaximum(_ maximum: UInt16, for identity: DisplayIdentity) async
}

public extension ExternalDisplayTransportProvider {
    func updateAssumedMaximum(_ maximum: UInt16, for identity: DisplayIdentity) async {
        _ = maximum
        _ = identity
    }
}

public struct DisplayTargetKey: Equatable, Hashable, Sendable {
    public let identity: DisplayIdentity
    public let displayID: UInt32

    public init(identity: DisplayIdentity, displayID: UInt32) {
        self.identity = identity
        self.displayID = displayID
    }
}

public struct ExternalDisplayTarget: Sendable {
    public let record: DisplayRecord
    public let sink: any ExternalBrightnessSink
    public let capability: ExternalDisplayCapability
    public let generation: UInt64

    public var key: DisplayTargetKey {
        DisplayTargetKey(identity: record.identity, displayID: record.displayID)
    }

    public init(
        record: DisplayRecord,
        sink: any ExternalBrightnessSink,
        capability: ExternalDisplayCapability = .verified(maximum: 100),
        generation: UInt64
    ) {
        self.record = record
        self.sink = sink
        self.capability = capability
        self.generation = generation
    }
}

public struct DisplayRuntimeState: Sendable {
    public let snapshot: DisplaySnapshot
    public let externalTargets: [ExternalDisplayTarget]

    public init(snapshot: DisplaySnapshot, externalTargets: [ExternalDisplayTarget]) {
        self.snapshot = snapshot
        self.externalTargets = externalTargets
    }
}

public protocol DisplayRuntimeProviding: Sendable {
    func runtimeState() async -> DisplayRuntimeState
    func markTargetDegraded(_ key: DisplayTargetKey, generation: UInt64) async
    func markTargetHealthy(_ key: DisplayTargetKey, generation: UInt64) async
    func retryTarget(_ key: DisplayTargetKey, generation: UInt64?) async
    func updateAssumedMaximum(_ maximum: UInt16, for identity: DisplayIdentity) async
}

public extension DisplayRuntimeProviding {
    func markTargetDegraded(_ key: DisplayTargetKey, generation: UInt64) async {
        _ = key
        _ = generation
    }

    func markTargetHealthy(_ key: DisplayTargetKey, generation: UInt64) async {
        _ = key
        _ = generation
    }

    func retryTarget(_ key: DisplayTargetKey, generation: UInt64?) async {
        _ = key
        _ = generation
    }

    func retryTarget(_ key: DisplayTargetKey) async {
        await retryTarget(key, generation: nil)
    }

    func updateAssumedMaximum(_ maximum: UInt16, for identity: DisplayIdentity) async {
        _ = maximum
        _ = identity
    }
}

public typealias DisplayStateUpdateHandler = @Sendable (DisplaySnapshot) -> Void
public typealias MeaningfulBrightnessUpdateHandler = @Sendable (Double) async -> Void
