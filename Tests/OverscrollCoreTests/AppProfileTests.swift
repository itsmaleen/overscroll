import Testing
@testable import OverscrollCore

@Suite("AppProfiles")
struct AppProfileTests {

    @Test("an unknown app gets no profile, leaving detection in charge")
    func unknownAppHasNoProfile() {
        #expect(AppProfiles.profile(appName: "Notes", windowTitle: "Shopping list") == nil)
    }

    @Test("WhatsApp starts on the HID tap")
    func whatsAppSkipsDeadRoute() {
        let profile = AppProfiles.profile(appName: "WhatsApp", windowTitle: "Sarah Chen")
        #expect(profile?.scrollRoute == .hidOnly)
        #expect(profile?.prefersOCR == false)
    }

    // The invisible bidi mark that WhatsApp prefixes everything with reaches the app name too.
    @Test("WhatsApp matches despite its invisible name prefix")
    func whatsAppWithBidiMark() {
        #expect(AppProfiles.profile(appName: "\u{200E}WhatsApp", windowTitle: nil)?.scrollRoute == .hidOnly)
    }

    // The app is the wrong unit for a browser: fine on most pages, blind on a canvas editor.
    @Test("a Google Doc in a browser starts on the pixel path")
    func googleDocPrefersOCR() {
        let profile = AppProfiles.profile(
            appName: "Google Chrome", windowTitle: "Quick Notes v1 Feedback - Google Docs"
        )
        #expect(profile?.prefersOCR == true)
    }

    @Test("Sheets and Slides are covered too")
    func otherCanvasEditors() {
        #expect(AppProfiles.profile(appName: "Helium", windowTitle: "Budget - Google Sheets")?.prefersOCR == true)
        #expect(AppProfiles.profile(appName: "Safari", windowTitle: "Deck - Google Slides")?.prefersOCR == true)
    }

    // The same browser on an ordinary page must not be forced onto the pixel path, which would
    // throw away real link targets and exact text for nothing.
    @Test("an ordinary page in the same browser is left alone")
    func ordinaryPageUnaffected() {
        #expect(AppProfiles.profile(appName: "Google Chrome", windowTitle: "Optical character recognition - Wikipedia") == nil)
    }

    @Test("a missing window title does not crash the match")
    func nilTitle() {
        #expect(AppProfiles.profile(appName: "Google Chrome", windowTitle: nil) == nil)
    }

    @Test("every profile explains itself")
    func profilesCarryRationale() {
        let profiles = [
            AppProfiles.profile(appName: "WhatsApp", windowTitle: nil),
            AppProfiles.profile(appName: "Chrome", windowTitle: "x - Google Docs"),
        ].compactMap { $0 }
        #expect(profiles.count == 2)
        #expect(profiles.allSatisfy { $0.rationale.count > 30 })
    }
}
