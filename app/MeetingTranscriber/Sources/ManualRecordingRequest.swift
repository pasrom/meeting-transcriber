import Foundation

/// What the user asked `WatchingController` to record by hand.
///
/// The two menu entry points differ only in what they target, and everything
/// around the start (the ownership guards, settling a racing auto start,
/// building the loop, the notification) is identical. Carrying the difference
/// as a value keeps that shared body in one place instead of two copies that
/// drift.
enum ManualRecordingRequest {
    case app(pid: pid_t, appName: String, title: String)
    case microphone
}
