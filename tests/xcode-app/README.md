# Xcode app integration harness

An iOS app (`A11yScanDemoApp`) that integrates the `a11y-scan` command plugin
through a pre-compile **build phase** — the official integration path for Xcode
projects (which have no `Package.swift` of their own). The project is described
as an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec so the generated
`.xcodeproj` does not need to be checked in.

```
xcode-app/
├── project.yml                   # XcodeGen spec (app + unit-test targets)
├── Package.swift                 # minimal scan driver hosting the command plugin
├── Sources/                      # @main app + ContentView with intentional a11y issues
├── Tests/                        # unit test target
└── scripts/run-a11y-scan.sh      # build-phase scan runner
```

## Generate the project

```bash
brew install xcodegen     # if not already installed
cd tests/xcode-app
xcodegen generate         # produces A11yScanDemoApp.xcodeproj
open A11yScanDemoApp.xcodeproj
```

## How the plugin is integrated

The app target has a **pre-compile build phase**, "BrowserStack Accessibility
Linter", that runs `scripts/run-a11y-scan.sh` before sources compile. The script
invokes the command plugin (`swift package plugin … scan`) against the minimal
`Package.swift`, scanning `Sources/` by include globs. `ENABLE_USER_SCRIPT_SANDBOXING`
is disabled in the spec so the scan can write the CLI cache to `~/.cache`.

## Build & test

```bash
export BROWSERSTACK_USERNAME=<your-username>
export BROWSERSTACK_ACCESS_KEY=<your-access-key>

xcodebuild \
  -project A11yScanDemoApp.xcodeproj \
  -scheme A11yScanDemoApp \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test
```

The scan runs as part of the build (pre-compile phase). It is configured with
`--non-strict` so issues are reported without failing the build; remove that
flag in `project.yml` to make accessibility violations fail the build. Without
credentials the scan phase no-ops with a warning so the build still succeeds.

> Requires `xcodegen` and Xcode; neither is exercised by `swift test`. This spec
> was authored to the documented integration but the generated project has not
> been built in this environment — generate and run it locally to validate on
> your toolchain.
