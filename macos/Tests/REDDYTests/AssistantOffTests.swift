import Testing
@testable import REDDY

@Suite("Setu is off for now") @MainActor struct AssistantOffTests {
    @Test func theSwitchIsOffAndNothingCanOpenTheAssistant() {
        #expect(AssistantFeature.isOn == false, "Setu stays off until it is upgraded; turn the flag on to bring it back")
        let before = AssistantLauncher.shared.opens
        AssistantLauncher.shared.ask("any question")
        AssistantLauncher.shared.ask(nil)
        #expect(AssistantLauncher.shared.opens == before, "no entry point opens it")
        #expect(AssistantLauncher.shared.request == nil)
    }
}
