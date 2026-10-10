// HIDThermalReader.swift

import Darwin
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "HIDThermalReader")

public nonisolated enum HIDThermalFailure: Error, Equatable, Sendable {
    case symbolsMissing
    case clientCreateFailed
    case noServices
}

/// Reads every vendor-defined thermal sensor (usage page 0xff00, usage 5)
/// through the private IOHID event-system client. The symbols are looked up
/// with `dlsym` rather than linked, so an OS that drops them degrades to
/// `.symbolsMissing` instead of failing to load the app.
public nonisolated enum HIDThermalReader {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private struct Symbols {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let floatValue: FloatValueFn
    }

    private static func load<T>(_ name: String, as _: T.Type) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let symbols: Symbols? = {
        guard let create = load("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let floatValue = load("IOHIDEventGetFloatValue", as: FloatValueFn.self)
        else { return nil }
        return Symbols(create: create, setMatching: setMatching, copyServices: copyServices,
                       copyProperty: copyProperty, copyEvent: copyEvent, floatValue: floatValue)
    }()

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    /// Client and filtered die-sensor services, built once and reused across
    /// ticks by the sampler actor (one service per distinct name). Dropped
    /// with the sampler on hide, so each show rebuilds it.
    public struct Session {
        fileprivate var client: CFTypeRef?
        fileprivate var sensors: [(name: String, service: CFTypeRef)] = []

        public init() {}
    }

    public static func readAll() -> Result<[NamedTemperature], HIDThermalFailure> {
        var session = Session()
        return readAll(session: &session)
    }

    public static func readAll(session: inout Session) -> Result<[NamedTemperature], HIDThermalFailure> {
        guard let symbols else { return .failure(.symbolsMissing) }
        if session.client == nil {
            guard let client = symbols.create(kCFAllocatorDefault)?.takeRetainedValue() else {
                return .failure(.clientCreateFailed)
            }
            let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
            symbols.setMatching(client, matching as CFDictionary)
            guard let services = symbols.copyServices(client)?.takeRetainedValue() as? [CFTypeRef],
                  !services.isEmpty
            else { return .failure(.noServices) }
            var seen = Set<String>()
            var sensors: [(name: String, service: CFTypeRef)] = []
            for service in services {
                guard let name = symbols.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                      CPUTemperatureAggregation.isCPUDieSensor(name),
                      seen.insert(name).inserted
                else { continue }
                sensors.append((name, service))
            }
            session.client = client
            session.sensors = sensors
        }

        var readings: [NamedTemperature] = []
        for (name, service) in session.sensors {
            guard let event = symbols.copyEvent(service, temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            readings.append(NamedTemperature(name: name, celsius: symbols.floatValue(event, temperatureField)))
        }
        if readings.isEmpty { session = Session() }
        return .success(readings)
    }

    static func log(_ disposition: FailureLogGate<HIDThermalFailure>.Disposition, failure: HIDThermalFailure?) {
        switch disposition {
        case .stillOK, .repeatedFailure:
            return
        case .firstFailure, .changedFailure:
            logger.notice("hid thermal: unavailable — \(String(describing: failure), privacy: .public)")
        case .recovered:
            logger.notice("hid thermal: recovered")
        }
    }
}
