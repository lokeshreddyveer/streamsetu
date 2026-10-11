import Foundation

final class SQLiteVideoPreferencesRepository: VideoPreferencesRepository {
    let db: DatabaseManager
    private static let globalKey = "*"
    init(db: DatabaseManager) { self.db = db }

    private func read(_ key: String) -> VideoLayoutSettings? {
        let json = try? db.read { try $0.queryOne("SELECT layout_json FROM video_layouts WHERE item_id=?", [key]) { $0.string(0) } }
        return json.flatMap { $0 }.flatMap { try? JSONDecoder().decode(VideoLayoutSettings.self, from: Data($0.utf8)) }
    }

    private func write(_ l: VideoLayoutSettings, _ key: String) {
        guard let data = try? JSONEncoder().encode(l), let json = String(data: data, encoding: .utf8) else { return }
        try? db.write { try $0.execute("INSERT OR REPLACE INTO video_layouts(item_id, layout_json, updated_at) VALUES(?,?,?)", [key, json, Date()]) }
    }

    func globalLayout() -> VideoLayoutSettings { read(Self.globalKey) ?? .default }
    func setGlobalLayout(_ l: VideoLayoutSettings) { write(l, Self.globalKey) }
    func layout(for itemID: String) -> VideoLayoutSettings? { read(itemID) }
    func setLayout(_ l: VideoLayoutSettings, for itemID: String) { write(l, itemID) }
    func clearLayout(for itemID: String) { try? db.write { try $0.execute("DELETE FROM video_layouts WHERE item_id=?", [itemID]) } }
}
