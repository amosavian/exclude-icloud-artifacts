import Testing
import Yams
@testable import exclude_icloud_artifacts

@Suite struct ExclusionRuleNameMatchTests {
    @Test func exactNameMatches() {
        #expect(ExclusionRule(".build").nameMatches(".build"))
        #expect(!ExclusionRule(".build").nameMatches(".buildx"))
        #expect(!ExclusionRule(".build").nameMatches("build"))
    }

    @Test func globNameMatches() {
        let rule = ExclusionRule("cmake-build-*")
        #expect(rule.nameMatches("cmake-build-debug"))
        #expect(rule.nameMatches("cmake-build-"))
        #expect(!rule.nameMatches("cmake-build"))
        #expect(!rule.nameMatches("xcmake-build-debug"))
    }

    @Test func questionMarkGlob() {
        let rule = ExclusionRule("cache?")
        #expect(rule.nameMatches("cache1"))
        #expect(!rule.nameMatches("cache"))
        #expect(!rule.nameMatches("cache12"))
    }

    @Test func bracketGlob() {
        let rule = ExclusionRule("v[12]")
        #expect(rule.nameMatches("v1"))
        #expect(rule.nameMatches("v2"))
        #expect(!rule.nameMatches("v3"))
    }
}

@Suite struct ExclusionRuleDecodingTests {
    @Test func missingGuardKeysDecodeAsEmpty() throws {
        let rules = try YAMLDecoder().decode(
            [ExclusionRule].self, from: "- folder: out\n")
        #expect(rules.count == 1)
        #expect(rules[0].folder == "out")
        #expect(rules[0].ifSiblingExists.isEmpty)
        #expect(rules[0].ifChildExists.isEmpty)
    }

    @Test func guardKeysDecode() throws {
        let yaml = """
            - folder: build
              ifSiblingExists: [pom.xml, build.gradle]
              ifChildExists: [marker]
            """
        let rules = try YAMLDecoder().decode([ExclusionRule].self, from: yaml)
        #expect(rules[0].ifSiblingExists == ["pom.xml", "build.gradle"])
        #expect(rules[0].ifChildExists == ["marker"])
    }
}

@Suite struct ExclusionRuleSiblingGuardTests {
    private func noChildren() -> Set<String> { [] }

    @Test func excludedOnlyWhenSiblingPresent() {
        let rule = ExclusionRule("target", ifSiblingExists: ["Cargo.toml"])
        #expect(rule.matches(
            directoryNamed: "target",
            siblings: ["Cargo.toml", "src"],
            children: noChildren))
        #expect(!rule.matches(
            directoryNamed: "target",
            siblings: ["src"],
            children: noChildren))
    }

    @Test func siblingPatternIsGlob() {
        let rule = ExclusionRule("bin", ifSiblingExists: ["*.csproj"])
        #expect(rule.matches(
            directoryNamed: "bin",
            siblings: ["App.csproj"],
            children: noChildren))
        #expect(!rule.matches(
            directoryNamed: "bin",
            siblings: ["App.txt"],
            children: noChildren))
    }

    @Test func nameMismatchShortCircuitsBeforeGuard() {
        let rule = ExclusionRule("target", ifSiblingExists: ["Cargo.toml"])
        #expect(!rule.matches(
            directoryNamed: "build",
            siblings: ["Cargo.toml"],
            children: noChildren))
    }
}

@Suite struct ExclusionRuleChildGuardTests {
    @Test func excludedOnlyWhenChildPresent() {
        let rule = ExclusionRule("venv", ifChildExists: ["pyvenv.cfg"])
        #expect(rule.matches(
            directoryNamed: "venv",
            siblings: [],
            children: { ["pyvenv.cfg", "bin"] }))
        #expect(!rule.matches(
            directoryNamed: "venv",
            siblings: [],
            children: { ["bin"] }))
    }

    @Test func wildcardNameWithChildMarker() {
        // The `general` preset's catch-all: any folder with CACHEDIR.TAG.
        let rule = ExclusionRule("*", ifChildExists: ["CACHEDIR.TAG"])
        #expect(rule.matches(
            directoryNamed: "anything",
            siblings: [],
            children: { ["CACHEDIR.TAG"] }))
        #expect(!rule.matches(
            directoryNamed: "anything",
            siblings: [],
            children: { ["data"] }))
    }

    @Test func childrenNotEvaluatedWhenNoChildGuard() {
        var called = false
        let rule = ExclusionRule("node_modules")
        _ = rule.matches(
            directoryNamed: "node_modules",
            siblings: [],
            children: { called = true; return [] })
        #expect(!called, "children() must stay lazy when there is no ifChildExists guard")
    }

    @Test func childrenNotEvaluatedWhenSiblingGuardFailsFirst() {
        var called = false
        let rule = ExclusionRule(
            "build",
            ifSiblingExists: ["pom.xml"],
            ifChildExists: ["marker"])
        _ = rule.matches(
            directoryNamed: "build",
            siblings: ["unrelated"],
            children: { called = true; return ["marker"] })
        #expect(!called, "sibling guard fails first, so children() must not run")
    }
}
