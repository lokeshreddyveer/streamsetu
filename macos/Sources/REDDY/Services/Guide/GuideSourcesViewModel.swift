import Foundation
import Observation

/// State behind Settings > Guide on Mac and iPhone: the sources with their health, adding and testing an address, refresh now, and the public database switch.
@MainActor @Observable final class GuideSourcesViewModel {
    var model: GuideSettingsModel?
    var message: String?
    var testing = false
    var refreshing = false
    var name = ""
    var address = ""

    func load(_ c: AppContainer?) {
        guard let c else { return }
        model = try? GuideSettingsModel.load(db: c.db, defaults: c.settings.defaultsStore)
    }
    func test(_ c: AppContainer?) async {
        guard let c else { return }
        testing = true; defer { testing = false }
        message = await c.guideManager.test(address).message
    }
    func add(_ c: AppContainer?) async {
        guard let c else { return }
        do {
            _ = try c.guideManager.add(name: name, address: address)
            name = ""; address = ""; message = "Guide added. Downloading it now."
            load(c)
            await refresh(c, force: true)
        } catch { message = error.localizedDescription }
    }
    func refresh(_ c: AppContainer?, force: Bool = true) async {
        guard let c else { return }
        refreshing = true; defer { refreshing = false }
        let r = await c.runGuideHub(force: force)
        let bad = r.values.filter { $0.outcome == "empty" || $0.outcome == "failed" }.count
        message = r.isEmpty ? "Nothing to refresh." : bad == 0 ? "Guides refreshed." : "\(Localized.plural(bad, one: "%@ guide", other: "%@ guides")) could not be used. See the details below."
        load(c)
    }
    func remove(_ id: String, _ c: AppContainer?) { guard let c else { return }; try? c.guideManager.remove(id); load(c) }
    func setEnabled(_ id: String, _ on: Bool, _ c: AppContainer?) { guard let c else { return }; try? SQLiteGuideRepository(db: c.db).setEnabled(id, on); load(c) }
    func setEnrichment(_ on: Bool, _ c: AppContainer?) {
        guard let c else { return }
        c.settings.defaultsStore.set(on, forKey: GuideSettingsModel.enrichmentKey)
        if !on { try? ChannelEnrichmentService(db: c.db).undoAll() }
        load(c)
        if on { Task { await refresh(c, force: true) } }
    }
}
