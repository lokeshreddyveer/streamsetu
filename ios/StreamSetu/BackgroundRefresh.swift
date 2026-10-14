import BackgroundTasks
import Foundation

/// Refreshes playlists while the app is closed. iOS decides when (usually while the phone is charging and on Wi-Fi), so this is a
/// best effort on top of the refresh that happens when the app is opened. It never runs while a stream is playing.
/// The system hands the task over on its own queue; it is only touched to report completion.
private final class TaskBox: @unchecked Sendable { let task: BGProcessingTask; init(_ t: BGProcessingTask) { task = t } }

enum BackgroundRefresh {
    static let identifier = "app.streamsetu.refresh"

    /// Must be called before the app has finished launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            schedule()
            let box = TaskBox(task)
            let work = Task { @MainActor in
                let task = box.task
                await IOSCoordinator.shared.boot()
                guard let container = IOSCoordinator.shared.container else { task.setTaskCompleted(success: false); return }
                await container.scheduler.checkNow(wait: true)
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Asks for the next run, about six hours from now at the earliest.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
