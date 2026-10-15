// Model.swift

import Foundation

struct Callout: Decodable {
    var text: String
    var detail: String?
    var keys: [String]?
    var duration: Double?
    var position: String?
}

struct Overlay: Decodable {
    var title: String
    var subtitle: String?
    var titleHold: Double?
    var callouts: [String: Callout]
    var speed: [String: Double]?
    var maxSpeedSeconds: Double?
    var maxSeconds: Double?
    var baseSpeed: Double?
    var endTitle: String?
    var endSubtitle: String?
}

struct CueSheet: Decodable {
    struct Cue: Decodable {
        var t: Double
        var kind: String
        var id: String
        var rect: [Double]?
    }

    var clip: String
    var duration: Double
    var cues: [Cue]
}

/// One stretch of the source that plays at one speed.
struct Segment {
    var src0: Double
    var src1: Double
    var speed: Double
    var out0: Double
    var ramp = false
    var isFast: Bool { speed > 1.01 }
    var out1: Double { out0 + (src1 - src0) / speed }
}

/// Source time to output time and back, over the trimmed, sped-up timeline.
struct Timeline {
    var segments: [Segment]

    var duration: Double { segments.last?.out1 ?? 0 }

    func output(forSource t: Double) -> Double {
        for s in segments where t < s.src1 {
            return s.out0 + max(0, t - s.src0) / s.speed
        }
        return duration
    }

    func source(forOutput t: Double) -> Double {
        for s in segments where t < s.out1 {
            return s.src0 + max(0, t - s.out0) * s.speed
        }
        return segments.last?.src1 ?? 0
    }
}

/// A punch-in on part of the source frame, in source pixels, over an output-time span.
struct Zoom {
    var out0: Double
    var out1: Double
    var rect: CGRect
}

func easeInOut(_ x: Double) -> Double {
    let c = max(0, min(1, x))
    return c * c * (3 - 2 * c)
}
