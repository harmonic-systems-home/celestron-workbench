import Foundation

/// The guided flow's steps (ADR 0022 amendment 7), shown as a strip along
/// the top of the window, with each automated step's designed time.
enum FlowStep: Int, CaseIterable, Identifiable, Comparable {
    case connect, track, find, cameraSettings, orientCamera, orientMoon, fineFocus, recheck, plan, start
    var id: Int { rawValue }
    static func < (a: FlowStep, b: FlowStep) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .connect: "Connect"
        case .track: "Track"
        case .find: "Find"
        case .cameraSettings: "Camera & coarse focus"
        case .orientCamera: "Orient Camera"
        case .orientMoon: "Orient Moon"
        case .fineFocus: "Fine focus"
        case .recheck: "Recheck"
        case .plan: "Plan"
        case .start: "Capture"
        }
    }

    /// Steps the operator does by hand, marked done by clicking them.
    var byHand: Bool { self == .cameraSettings || self == .fineFocus }

    /// The designed duration (amendment 7's time budget); nil for steps done
    /// by hand or sized by the plan.
    var estimateSeconds: Double? {
        switch self {
        case .connect: 10
        case .track: 1
        case .find: 60
        case .orientCamera: 20
        case .orientMoon: 60
        case .recheck: 30
        case .plan: 1
        case .cameraSettings, .fineFocus, .start: nil
        }
    }
}
