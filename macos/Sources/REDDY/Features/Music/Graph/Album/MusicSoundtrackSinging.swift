import Foundation

/// Which `performedBy` credits count as singing. A session guitarist, a conductor or a remixer performed on a song but did not sing it, and an actor (a mistaken
/// role on that edge) never sings: only a singer, a performer or a featured artist is a singer on an album page.
enum MusicSoundtrackSinging {
    static let roles: Set<MusicRole> = [.singer, .performer, .featured]

    static func isSinger(_ e: MusicEdge) -> Bool {
        guard let role = MusicPersonRoles.effectiveRole(e) else { return false }
        return roles.contains(role)
    }
}
