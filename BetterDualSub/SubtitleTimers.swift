import Foundation

/// What keeps the displayed subtitles current while playing: a slow periodic tick that moves the position readouts,
/// a one-shot timer set for the next cue start or end so lines change on time, and an activity that stops App Nap
/// from delaying either. The manager decides when each is wanted; this owns the timers.
@MainActor
final class SubtitleTimers {
    /// Called by either timer.
    var onFire: () -> Void = {}
    private var periodic: Timer?
    private var periodicInterval: TimeInterval?
    private var cue: Timer?
    private var cueFireUptime: TimeInterval?
    private var activity: NSObjectProtocol?

    /// Ticks every `interval` seconds, or not at all for nil. Asking again for the running interval changes nothing.
    func setPeriodic(interval: TimeInterval?) {
        guard periodicInterval != interval else { return }
        periodic?.invalidate()
        periodic = nil
        periodicInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFire() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        periodic = timer
    }

    /// Fires once at `uptime` (`ProcessInfo.systemUptime`), or cancels for nil. A request within 4 ms of the one
    /// already waiting keeps it, as every tick asks again.
    func scheduleCue(atUptime uptime: TimeInterval?) {
        guard let uptime else {
            cue?.invalidate()
            cue = nil
            cueFireUptime = nil
            return
        }
        if let cueFireUptime, cue?.isValid == true, abs(cueFireUptime - uptime) < 0.004 { return }
        cue?.invalidate()
        cueFireUptime = uptime
        let timer = Timer(timeInterval: max(0, uptime - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cueFireUptime = nil
                self?.onFire()
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        cue = timer
    }

    func setKeepingAwake(_ on: Bool) {
        if on {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Synchronize subtitles with playback.")
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
