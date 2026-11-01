import Testing
@testable import MurmurCore

@Suite struct VoiceControlTests {
    let parser = ControlParser(apps: ["Safari", "Google Chrome", "Visual Studio Code", "Messages", "Mail", "Microsoft Word",
                                      "System Settings", "Spotify", "Terminal", "Notes", "zoom.us", "FaceTime", "Finder"])

    func one(_ s: String) -> ControlAction? {
        if case .actions(let a) = parser.parse(s), a.count == 1 { return a[0] }
        return nil
    }

    @Test func opensAppsByNameAndAlias() {
        #expect(one("Open Safari.") == .openApp("Safari"))
        #expect(one("open chrome") == .openApp("Google Chrome"))
        #expect(one("Switch to Messages") == .openApp("Messages"))
        #expect(one("launch vs code") == .openApp("Visual Studio Code"))
        #expect(one("open visual studio") == .openApp("Visual Studio Code"))
        #expect(one("Can you open settings please") == .openApp("System Settings"))
        #expect(one("open zoom") == .openApp("zoom.us"))
        #expect(one("open face time") == .openApp("FaceTime"))
        #expect(one("open the terminal app") == .openApp("Terminal"))
        #expect(one("open safary") == .openApp("Safari"))
    }

    @Test func opensSitesUrlsAndFolders() {
        #expect(one("open google") == .openURL("https://www.google.com"))
        #expect(one("go to youtube") == .openURL("https://www.youtube.com"))
        #expect(one("Go to github dot com.") == .openURL("https://github.com"))
        #expect(one("go to news.ycombinator.com") == .openURL("https://news.ycombinator.com"))
        #expect(one("open downloads") == .openFolder("~/Downloads"))
        // An installed app beats its site.
        #expect(one("open spotify") == .openApp("Spotify"))
    }

    @Test func unknownOpenTargetSearches() {
        #expect(one("open the quarterly report") == .search("quarterly report", site: .web))
    }

    @Test func searches() {
        #expect(one("Search for best pizza near me.") == .search("best pizza near me", site: .web))
        #expect(one("google how tall is everest") == .search("how tall is everest", site: .web))
        #expect(one("look up mitochondria") == .search("mitochondria", site: .web))
        #expect(one("search youtube for lofi beats") == .search("lofi beats", site: .youtube))
        #expect(one("search for usb c cables on amazon") == .search("usb c cables", site: .amazon))
        #expect(one("play never gonna give you up on youtube") == .search("never gonna give you up", site: .youtube))
        #expect(one("youtube cat videos") == .search("cat videos", site: .youtube))
        #expect(one("directions to the airport") == .search("the airport", site: .directions))
        #expect(one("search salt and pepper") == .search("salt and pepper", site: .web))
        #expect(one("find me a coffee shop") == .search("a coffee shop", site: .web))
        #expect(one("What is the weather in Atlanta tomorrow?") == .search("what is the weather in atlanta tomorrow", site: .web))
        #expect(one("Show me how to tie a tie on YouTube") == .search("how to tie a tie", site: .youtube))
    }

    @Test func searchUrlsEncodeTheQuery() {
        #expect(SearchSite.web.url("c++ & rust") == "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
    }

    @Test func shortcuts() {
        #expect(one("new tab") == .keys(KeyChord("t", command: true)))
        #expect(one("Close this tab.") == .keys(KeyChord("w", command: true)))
        #expect(one("go back") == .keys(KeyChord("[", command: true)))
        #expect(one("next tab") == .keys(KeyChord("tab", control: true)))
        #expect(one("refresh the page") == .keys(KeyChord("r", command: true)))
        #expect(one("scroll down") == .scroll(.down))
        #expect(one("scroll to the top") == .keys(KeyChord("up", command: true)))
    }

    @Test func windowsAndMedia() {
        #expect(one("put this window on the left half") == .keys(KeyChord("left", control: true)))
        #expect(one("Maximize.") == .keys(KeyChord("f", control: true, fn: true)))
        #expect(one("turn the volume up") == .media(.volumeUp))
        #expect(one("next song") == .media(.next))
        #expect(one("check my email") == .openApp("Mail"))
        #expect(parser.action(fromModelJSON: #"{"action":"media","target":"volume_down"}"#) == .media(.volumeDown))
    }

    @Test func pressKeysOrButtons() {
        #expect(one("press command shift t") == .keys(KeyChord("t", command: true, shift: true)))
        #expect(one("Press Enter.") == .keys(KeyChord("return")))
        #expect(one("hit escape") == .keys(KeyChord("escape")))
        #expect(one("press control plus tab") == .keys(KeyChord("tab", control: true)))
        #expect(one("press command plus") == .keys(KeyChord("=", command: true)))
        #expect(one("press F5") == .keys(KeyChord("f5")))
        #expect(one("Press Command-Shift-T.") == .keys(KeyChord("t", command: true, shift: true)))
        #expect(one("press cmd+s") == .keys(KeyChord("s", command: true)))
        #expect(one("press the submit button") == .click("submit"))
        #expect(one("click on Sign In") == .click("Sign In"))
    }

    @Test func typeKeepsCapitalsAndPunctuation() {
        #expect(one("type Hello, Dr. Smith") == .type("Hello, Dr. Smith"))
        #expect(one("type see you at 5.") == .type("see you at 5"))
    }

    @Test func findInPage() {
        #expect(one("find budget") == .findInPage("budget"))
    }

    @Test func quits() {
        #expect(one("quit spotify") == .quitApp("Spotify"))
        #expect(one("close safari") == .quitApp("Safari"))
        #expect(one("quit") == .quitApp(nil))
        #expect(one("close") == .keys(KeyChord("w", command: true)))
    }

    @Test func sequences() {
        #expect(parser.parse("open safari and then new tab") == .actions([.openApp("Safari"), .keys(KeyChord("t", command: true))]))
        #expect(parser.parse("Open Chrome, then search for weather in Atlanta.")
            == .actions([.openApp("Google Chrome"), .search("weather in atlanta", site: .web)]))
        #expect(parser.parse("new tab and go to github.com and scroll down")
            == .actions([.keys(KeyChord("t", command: true)), .openURL("https://github.com"), .scroll(.down)]))
        // A weak guess on the left does not split: the whole is one command.
        #expect(parser.parse("open tom and jerry") == .actions([.search("tom and jerry", site: .web)]))
    }

    @Test func incompleteAndUnknown() {
        #expect(parser.parse("search for") == .incomplete)
        #expect(parser.parse("Open...") == .incomplete)
        #expect(parser.parse("click") == .incomplete)
        #expect(parser.parse("make this text bold and send it to Sarah") == .unknown)
        #expect(parser.parse("") == .unknown)
    }

    @Test func modelJSON() {
        #expect(parser.action(fromModelJSON: #"{"action":"open","target":"chrome"}"#) == .openApp("Google Chrome"))
        #expect(parser.action(fromModelJSON: #"sure: {"action":"search","target":"cats","site":"youtube"}"#)
            == .search("cats", site: .youtube))
        #expect(parser.action(fromModelJSON: #"{"action":"keys","target":"command+shift+t"}"#)
            == .keys(KeyChord("t", command: true, shift: true)))
        #expect(parser.action(fromModelJSON: #"{"action":"none"}"#) == nil)
        #expect(parser.action(fromModelJSON: "no json") == nil)
        #expect(parser.action(fromModelJSON: #"{"action":"shell","target":"rm -rf ~"}"#) == nil)
    }

    @Test func appMatcherStrengths() {
        let apps = ["Safari", "Google Chrome", "Microsoft Word"]
        #expect(AppMatcher.match("safari", among: apps)?.strength == .exact)
        #expect(AppMatcher.match("google", among: apps)?.strength == .prefix)
        #expect(AppMatcher.match("word", among: apps) == .init(name: "Microsoft Word", strength: .exact))
        #expect(AppMatcher.match("xyz", among: apps) == nil)
    }
}
