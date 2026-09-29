import Foundation

/// Upstream CodeView smooth-scroll settings. Time and velocity use milliseconds.
public struct SmoothScrollSettings: Equatable, Sendable {
    var isValid: Bool {
        omega.isFinite && omega > 0 && positionEpsilon.isFinite && positionEpsilon >= 0
            && velocityEpsilon.isFinite && velocityEpsilon >= 0
    }
    public var omega: Double
    public var positionEpsilon: Double
    public var velocityEpsilon: Double
    public init(omega: Double = 0.015, positionEpsilon: Double = 0.5, velocityEpsilon: Double = 0.05) {
        self.omega = omega; self.positionEpsilon = positionEpsilon; self.velocityEpsilon = velocityEpsilon
    }
}

/// Closed-form critically damped step from upstream CodeView. Keeping this
/// independent of the frame driver permits testing irregular frame intervals.
struct ScrollSpring {
    var position: Double
    var velocity: Double = 0
    var lastTimestamp: Double
    mutating func advance(to destination: Double, timestamp: Double, anchorDelta: Double = 0,
                          settings: SmoothScrollSettings = .init()) -> Bool {
        position += anchorDelta
        let dt = max(0, timestamp - lastTimestamp)
        let decay = exp(-settings.omega * dt)
        let displacement = position - destination
        let coefficient = velocity + settings.omega * displacement
        position = destination + (displacement + coefficient * dt) * decay
        velocity = (coefficient * (1 - settings.omega * dt) - settings.omega * displacement) * decay
        lastTimestamp = timestamp
        if abs(destination - position) <= settings.positionEpsilon && abs(velocity) <= settings.velocityEpsilon {
            position = destination; velocity = 0
            return true
        }
        return false
    }
}
