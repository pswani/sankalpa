import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

@Suite("Service location")
struct ServiceLocationTests {

    /// Someone reading a name off a Mac's sharing settings, or pasting a URL from a browser, has
    /// the same thing in mind. Refusing one of those spellings would be the app being pedantic
    /// about something it can work out.
    @Test(
        "Reads the spellings a person actually has to hand",
        arguments: [
            ("studio.local", "studio.local", 8080),
            ("studio.local:9000", "studio.local", 9000),
            ("http://studio.local:9000", "studio.local", 9000),
            ("https://studio.local", "studio.local", 8080),
            ("http://studio.local:9000/api/v1", "studio.local", 9000),
            ("  studio.local  ", "studio.local", 8080),
            ("192.168.1.24:8080", "192.168.1.24", 8080)
        ]
    )
    func readsHostAndPort(text: String, host: String, port: Int) {
        let location = ServiceLocation(text: text)
        #expect(location?.host == host)
        #expect(location?.port == port)
    }

    /// A setting that can only ever fail is worse than no setting: the app would look broken
    /// rather than misconfigured.
    @Test(
        "Refuses what cannot name a computer",
        arguments: [
            "", "   ", "studio local", "studio.local:0", "studio.local:70000",
            "studio.local:abc", "fe80::1", "what?"
        ]
    )
    func refusesNonsense(text: String) {
        #expect(ServiceLocation(text: text) == nil)
    }

    @Test("The default port is left out of what is shown")
    func displayTextHidesTheDefaultPort() {
        #expect(ServiceLocation(host: "studio.local").displayText == "studio.local")
        #expect(ServiceLocation(host: "studio.local", port: 9000).displayText == "studio.local:9000")
    }

    @Test("The URL is the one the client will call")
    func buildsTheURL() {
        #expect(
            ServiceLocation(host: "studio.local", port: 9000).url.absoluteString
                == "http://studio.local:9000"
        )
    }

    // MARK: - Where the answer comes from

    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    @Test("With nothing set, the simulator's own machine is the answer")
    func defaultsToLocalhost() {
        let store = ServiceLocationStore(defaults: defaults(), environment: [:])
        #expect(store.current == ServiceLocation.simulatorDefault)
        #expect(store.stored == nil)
    }

    @Test("What the person chose is remembered")
    func remembersWhatWasChosen() {
        let suite = defaults()
        let store = ServiceLocationStore(defaults: suite, environment: [:])
        store.save(ServiceLocation(host: "studio.local", port: 9000))

        let reopened = ServiceLocationStore(defaults: suite, environment: [:])
        #expect(reopened.current == ServiceLocation(host: "studio.local", port: 9000))
    }

    /// A UI run points the app at its own throwaway service. That has to win, and it has to do so
    /// without overwriting what the person using the app chose.
    @Test("A launch setting wins, and leaves the stored choice alone")
    func environmentWins() {
        let suite = defaults()
        let store = ServiceLocationStore(defaults: suite, environment: [:])
        store.save(ServiceLocation(host: "studio.local"))

        let overridden = ServiceLocationStore(
            defaults: suite,
            environment: [ServiceLocationStore.environmentKey: "http://localhost:8181"]
        )

        #expect(overridden.current == ServiceLocation(host: "localhost", port: 8181))
        #expect(overridden.isOverriddenByEnvironment)
        #expect(overridden.stored == ServiceLocation(host: "studio.local"))
    }

    @Test("A launch setting that is not a computer name is ignored rather than obeyed")
    func nonsenseEnvironmentIsIgnored() {
        let store = ServiceLocationStore(
            defaults: defaults(),
            environment: [ServiceLocationStore.environmentKey: "not a host"]
        )
        #expect(!store.isOverriddenByEnvironment)
        #expect(store.current == ServiceLocation.simulatorDefault)
    }
}
