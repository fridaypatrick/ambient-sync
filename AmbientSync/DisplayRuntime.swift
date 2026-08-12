import Foundation

public enum DisplaySupportStatus: String, Equatable, Sendable {
    case builtIn
    case controllableExternal
    case unsupportedExternal
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

    public init(record: DisplayRecord, support: DisplaySupportStatus) {
        self.record = record
        self.support = support
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

    public init(record: DisplayRecord, sink: any ExternalBrightnessSink) {
        self.record = record
        self.sink = sink
    }
}

public protocol ExternalDisplayTransportProvider: Sendable {
    func rebuild(for displays: [DisplayRecord]) async -> [ExternalDisplayBinding]
    func invalidate() async
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
    public let generation: UInt64

    public var key: DisplayTargetKey {
        DisplayTargetKey(identity: record.identity, displayID: record.displayID)
    }

    public init(
        record: DisplayRecord,
        sink: any ExternalBrightnessSink,
        generation: UInt64
    ) {
        self.record = record
        self.sink = sink
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
}

public typealias DisplayStateUpdateHandler = @Sendable (DisplaySnapshot) -> Void
public typealias MeaningfulBrightnessUpdateHandler = @Sendable (Double) async -> Void
