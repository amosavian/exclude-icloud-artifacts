/// Named groups of exclusion rules for common languages and tools.
/// Enable them in config.yaml via `presets: [swift, node, ...]`.
enum Preset {
    static let all: [String: [ExclusionRule]] = [
        "swift": [
            .init(".build"),
            .init("DerivedData"),
            .init("Pods"),
            .init("Carthage"),
            .init(".docc-build"),
        ],
        "node": [
            .init("node_modules"),
            .init(".npm"),
            .init(".next"),
            .init(".nuxt"),
            .init(".astro"),
            .init(".docusaurus"),
            .init(".turbo"),
            .init(".parcel-cache"),
            .init(".angular"),
            .init(".expo"),
            .init(".metro-cache"),
        ],
        "python": [
            .init("__pycache__"),
            .init(".venv"),
            .init("venv", ifChildExists: ["pyvenv.cfg"]),
            .init(".pixi"),
            .init(".tox"),
            .init(".nox"),
            .init(".pytest_cache"),
            .init(".mypy_cache"),
            .init(".ruff_cache"),
            .init(".hypothesis"),
            .init(".ipynb_checkpoints"),
        ],
        "java": [
            .init(".gradle"),
            .init(".m2"),
            .init(".kotlin"),
            .init(".cxx"),
            .init("build", ifSiblingExists: [
                "build.gradle", "build.gradle.kts",
                "settings.gradle", "settings.gradle.kts",
                "pom.xml",
            ]),
            .init("target", ifSiblingExists: ["pom.xml"]),
        ],
        "rust": [
            .init("target", ifSiblingExists: ["Cargo.toml"]),
        ],
        "dotnet": [
            .init("bin", ifSiblingExists: ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"]),
            .init("obj", ifSiblingExists: ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"]),
        ],
        "go": [
            .init("vendor", ifSiblingExists: ["go.mod"]),
        ],
        "php": [
            .init("vendor", ifSiblingExists: ["composer.json"]),
        ],
        "ruby": [
            .init("vendor", ifSiblingExists: ["Gemfile"]),
            .init(".jekyll-cache"),
            .init("_site", ifSiblingExists: ["_config.yml"]),
        ],
        "dart": [
            .init(".dart_tool"),
            .init("build", ifSiblingExists: ["pubspec.yaml"]),
        ],
        "elixir": [
            .init("_build"),
            .init("deps", ifSiblingExists: ["mix.exs"]),
        ],
        "haskell": [
            .init(".stack-work"),
            .init("dist-newstyle"),
        ],
        "scala": [
            .init("target", ifSiblingExists: ["build.sbt"]),
            .init(".bloop"),
            .init(".metals"),
            .init(".bsp"),
        ],
        "zig": [
            .init(".zig-cache"),
            .init("zig-cache"),
            .init("zig-out"),
        ],
        "cpp": [
            .init("cmake-build-*"),
            .init(".clangd"),
            .init(".ccls-cache"),
        ],
        "unity": [
            .init("Library", ifSiblingExists: ["ProjectSettings"]),
            .init("Temp", ifSiblingExists: ["ProjectSettings"]),
            .init("Logs", ifSiblingExists: ["ProjectSettings"]),
            .init("obj", ifSiblingExists: ["ProjectSettings"]),
        ],
        "cloud": [
            .init(".terraform"),
            .init(".terragrunt-cache"),
            .init(".vagrant"),
            .init(".serverless"),
            .init(".firebase"),
            .init("cdk.out"),
            .init(".aws-sam"),
        ],
        "general": [
            .init(".cache"),
            // Cache Directory Tagging Specification (https://bford.info/cachedir/):
            // any folder containing CACHEDIR.TAG declares itself regenerable
            // cache. Cargo writes it into target/, other tools follow suit.
            .init("*", ifChildExists: ["CACHEDIR.TAG"]),
        ],
    ]
}
