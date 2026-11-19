// StartupCommandDeliveryEventTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class OrderedSink: TerminalInputSink {
    var log: [String] = []
    var refuse = false

    func paste(text: String) -> Bool {
        log.append("paste:\(text)")
        return !refuse
    }

    func pressReturn() -> Bool {
        log.append("return")
        return !refuse
    }
}

@MainActor
struct StartupCommandDeliveryEventTests {
    @Test func willTypeFiresBeforeTheFirstLineIsTyped() async {
        let sink = OrderedSink()
        let delivery = StartupCommandDelivery(command: "make test", sink: sink) { event in
            sink.log.append("event:\(event)")
        }
        delivery.deliverOnNextMainTurn()
        await delivery.waitUntilFinished()
        #expect(sink.log.first == "event:willType")
        #expect(sink.log.contains("paste:make test"))
        #expect(sink.log.filter { $0.hasPrefix("event:") } == ["event:willType"])
    }

    @Test func refusedInputReportsRefused() async {
        let sink = OrderedSink()
        sink.refuse = true
        var events: [StartupCommandDeliveryEvent] = []
        let delivery = StartupCommandDelivery(command: "make test", sink: sink) { events.append($0) }
        delivery.deliverOnNextMainTurn()
        await delivery.waitUntilFinished()
        #expect(events == [.willType, .refused])
    }

    @Test func abandonBeforeDeliveryReportsAbandoned() async {
        var events: [StartupCommandDeliveryEvent] = []
        let delivery = StartupCommandDelivery(command: "make test", sink: OrderedSink()) { events.append($0) }
        delivery.abandon()
        delivery.abandon()
        await delivery.waitUntilFinished()
        #expect(events == [.abandoned])
    }

    @Test func abandonAfterDeliveryReportsNothing() async {
        var events: [StartupCommandDeliveryEvent] = []
        let delivery = StartupCommandDelivery(command: "make test", sink: OrderedSink()) { events.append($0) }
        delivery.deliverOnNextMainTurn()
        await delivery.waitUntilFinished()
        delivery.abandon()
        #expect(events == [.willType])
    }
}
