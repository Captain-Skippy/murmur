import Testing
@testable import MurmurCore

@Suite struct SpokenFormatTests {
    @Test func identifiers() {
        #expect(SpokenFormat.apply("The environment variable is murmur underscore sign underscore identity all caps.", style: .code)
                == "The environment variable is MURMUR_SIGN_IDENTITY.")
        #expect(SpokenFormat.apply("call load underscore models now", style: .neutral) == "call load_models now")
    }

    @Test func flagsAndHyphens() {
        #expect(SpokenFormat.apply("Run murmur bench dash ASR with dash dash stacks parakey dash v2 and dash dash limit 40", style: .terminal)
                == "Run murmur bench-ASR with --stacks parakey-v2 and --limit 40")
        // Outside code, a spoken "dash" between words is left to the model.
        #expect(SpokenFormat.apply("a dash of salt", style: .casual) == "a dash of salt")
    }

    @Test func extensionsSlashesEmails() {
        #expect(SpokenFormat.apply("open controller dot swift", style: .code) == "open controller.swift")
        #expect(SpokenFormat.apply("open github.com slash captain-skippy slash murmur", style: .neutral) == "open github.com/captain-skippy/murmur")
        #expect(SpokenFormat.apply("Email me at sam.lee at example.com by five", style: .neutral) == "Email me at sam.lee@example.com by five")
        #expect(SpokenFormat.apply("I'm an AI slash ML engineer", style: .neutral) == "I'm an AI/ML engineer")
        // "at" before a non-domain is a word.
        #expect(SpokenFormat.apply("meet me at noon", style: .neutral) == "meet me at noon")
        #expect(SpokenFormat.apply("a dot on the map", style: .neutral) == "a dot on the map")
    }

    @Test func leadingBullets() {
        #expect(SpokenFormat.apply("Bullets. Finish the history essay, email the TA about the regrade, and book the study room.", style: .neutral)
                == "- Finish the history essay\n- Email the TA about the regrade\n- Book the study room")
        #expect(SpokenFormat.apply("Bullets are fun, cheap, and fast", style: .neutral) == "Bullets are fun, cheap, and fast")
    }
}
