import Testing
import Foundation
@testable import REDDY

/// With the left sidebar on auto-hide, the open sidebar is a second view that goes away as soon as the pointer leaves it, and the pointer leaves it to reach
/// the alert it just opened. The New playlist, Rename and Delete state therefore lives in the shared `MusicSidebarDialogs` model of the shell, so closing the
/// peek cannot take an open dialog (or the text typed in it) with it.
@MainActor
@Suite("Flow: sidebar dialogs survive the auto-hide peek closing")
struct SidebarDialogsPeekFlowTests {
    private func make() throws -> FlowRig { try FlowRig() }

    @Test func renameKeepsItsTextAndStillRenamesAfterThePeekMayClose() throws {
        let rig = try make(); defer { rig.cleanup() }
        let dialogs = MusicSidebarDialogs()
        let p = rig.hub.library.createPlaylist(name: "Old name", tracks: [])

        dialogs.startRename(p)
        #expect(dialogs.renaming?.id == p.id && dialogs.renameText == "Old name")
        // The pointer leaves the sidebar for the alert: with no menu open the peek is allowed to close, and its view (not the model) goes away.
        #expect(MusicSidebarPeek.mayClose(menuTracking: false))
        #expect(dialogs.renaming?.id == p.id, "closing the peek must not clear the rename")

        dialogs.renameText = "  New name "
        dialogs.confirmRename(hub: rig.hub)

        #expect(rig.hub.library.playlist(id: p.id)?.name == "New name")
        #expect(dialogs.renaming == nil)
    }

    @Test func newPlaylistIsCreatedAndOpenedAfterThePeekClosed() throws {
        let rig = try make(); defer { rig.cleanup() }
        let dialogs = MusicSidebarDialogs()
        let before = rig.hub.library.playlists.count

        dialogs.startCreate()
        #expect(dialogs.creating && dialogs.newName.isEmpty)
        #expect(MusicSidebarPeek.mayClose(menuTracking: false))
        dialogs.newName = "  Road trip "
        dialogs.confirmCreate(hub: rig.hub)

        #expect(!dialogs.creating)
        #expect(rig.hub.library.playlists.count == before + 1)
        let made = try #require(rig.hub.library.playlists.last)
        #expect(made.name == "Road trip")
        #expect(rig.hub.nav.top == .localPlaylist(made.id))
    }

    @Test func aBlankNameCreatesAndRenamesNothing() throws {
        let rig = try make(); defer { rig.cleanup() }
        let dialogs = MusicSidebarDialogs()
        let p = rig.hub.library.createPlaylist(name: "Keep me", tracks: [])
        let count = rig.hub.library.playlists.count

        dialogs.startCreate(); dialogs.newName = "   "; dialogs.confirmCreate(hub: rig.hub)
        dialogs.startRename(p); dialogs.renameText = " "; dialogs.confirmRename(hub: rig.hub)

        #expect(rig.hub.library.playlists.count == count)
        #expect(rig.hub.library.playlist(id: p.id)?.name == "Keep me")
        #expect(!dialogs.creating && dialogs.renaming == nil)
    }

    @Test func deleteRemovesThePlaylistAndItsPage() throws {
        let rig = try make(); defer { rig.cleanup() }
        let dialogs = MusicSidebarDialogs()
        let p = rig.hub.library.createPlaylist(name: "Gone soon", tracks: [])
        rig.hub.open(.localPlaylist(p.id))

        dialogs.startDelete(p)
        #expect(dialogs.deleting?.id == p.id)
        dialogs.confirmDelete(hub: rig.hub)

        #expect(rig.hub.library.playlist(id: p.id) == nil)
        #expect(dialogs.deleting == nil)
        #expect(rig.hub.nav.top != .localPlaylist(p.id))
    }

    @Test func aMenuOpenFromTheSidebarKeepsThePeekOpenAndLeavingTheShellDismissesTheDialogs() {
        #expect(!MusicSidebarPeek.mayClose(menuTracking: true))
        let dialogs = MusicSidebarDialogs()
        dialogs.startCreate()
        dialogs.dismissAll()
        #expect(!dialogs.creating && dialogs.renaming == nil && dialogs.deleting == nil)
    }

    /// The structure that makes the above true: no sidebar view keeps this state itself, and the alerts hang off the shell's host modifier only.
    @Test func theSidebarViewsHoldNoDialogStateOfTheirOwn() throws {
        let file = try #require(GuardScanner.files(under: ["Features/Music"]).first { $0.path == "Features/Music/MusicSidebar.swift" })
        let code = file.code
        let viewStart = try #require(code.range(of: "struct MusicSidebar: View"))
        let inViews = String(code[viewStart.lowerBound...])
        for banned in ["@State private var creating", "@State private var renaming", "@State private var deleting", "@State private var newName", "@State private var renameText", ".alert(", ".confirmationDialog("] {
            #expect(!inViews.contains(banned), "the sidebar view must not own \(banned)")
        }
        let main = try #require(GuardScanner.files(under: ["Features/Music"]).first { $0.path == "Features/Music/MusicMainView.swift" })
        #expect(main.code.components(separatedBy: "MusicSidebarDialogsHost(").count == 2, "the host is applied once, on the shell")
    }
}
