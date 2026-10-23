#!/usr/bin/env bash
# Tests for the SwiftPM plugin's download-URL policy (DEVA11Y-479/488): the
# --download-url / BROWSERSTACK_A11Y_CLI_DOWNLOAD_URL override is accepted only for
# https on browserstack.com or a subdomain. Lifts parseOverride, isAllowedRedirectTarget,
# RedirectPolicyDelegate, extractVersion and PluginError verbatim from the plugin source, so the cases run against the shipped
# code rather than a copy. No network, no credentials.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PLUGIN="$ROOT/Plugins/BrowserStackAccessibilityLint/BrowserStackAccessibilityLint.swift"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Lift a top-level declaration (its first line to the first bare }).
extract() {
  awk -v start="$1" 'index($0,start)==1{p=1} p{print} p&&/^}$/{exit}' "$PLUGIN"
}

{
  echo 'import Foundation'
  for decl in 'private func parseOverride(' 'private func isAllowedRedirectTarget(' 'private final class RedirectPolicyDelegate' 'private func extractVersion(' 'private struct PluginError'; do
    body=$(extract "$decl")
    if [[ -z "$body" ]]; then
      echo "could not find '$decl' in $PLUGIN" >&2
      exit 1
    fi
    printf '%s\n\n' "$body"
  done
  cat <<'SWIFT'
// accept: parseOverride returns a URL; reject: it throws. nil input is a no-op.
let cases: [(String?, Bool)] = [
    (nil, true),
    ("", true),
    ("https://api.browserstack.com/sdk/v1/download_cli?os=macos&os_arch=arm64", true),
    ("https://sdk-assets.browserstack.com/cli/binary-1.2.3.zip", true),
    ("https://browserstack.com/cli.zip", true),
    ("HTTPS://API.BROWSERSTACK.COM/cli.zip", true),
    ("https://api.browserstack.com:443/cli.zip", true),
    ("https://evil.example/cli.zip", false),
    ("https://github.com/browserstack/cli/releases/download/v1/cli.zip", false),
    ("https://evilbrowserstack.com/cli.zip", false),
    ("https://browserstack.com.evil.example/cli.zip", false),
    ("https://api.browserstack.com@evil.example/cli.zip", false),
    ("https://api.browserstack.com:x@evil.example/cli.zip", false),
    ("https://evil.example/api.browserstack.com/cli.zip", false),
    ("https://evil.example/?h=.browserstack.com", false),
    ("https://127.0.0.1/cli.zip", false),
    ("https://169.254.169.254/latest/meta-data/", false),
    ("http://api.browserstack.com/cli.zip", false),
    ("file:///tmp/cli.zip", false),
    ("file://api.browserstack.com/tmp/cli.zip", false),
    ("/tmp/cli.zip", false),
    ("ftp://api.browserstack.com/cli.zip", false),
    ("https:///cli.zip", false),
]

var failures = 0
for (input, wantAccept) in cases {
    let accepted: Bool
    var policyHolds = true
    do {
        let url = try parseOverride(urlString: input)
        accepted = true
        if let url, !isAllowedRedirectTarget(url) {
            policyHolds = false
        }
    } catch {
        accepted = false
    }
    let label = input.map { "'\($0)'" } ?? "nil"
    if !policyHolds {
        print("FAIL  accepted URL fails the host policy: \(label)")
        failures += 1
    } else if accepted == wantAccept {
        print("ok    \(wantAccept ? "accept" : "reject") \(label)")
    } else {
        print("FAIL  want \(wantAccept ? "accept" : "reject"), got \(accepted ? "accept" : "reject") \(label)")
        failures += 1
    }
}
// extractVersion: the version becomes a cache path component, so it must never be a
// traversal segment or the cache root itself.
let versionCases: [(String, String?)] = [
    ("binary-macos-arm64-1.63.0.zip", "1.63.0"),
    ("binary-macos-arm64-..zip", nil),
    ("binary-macos-arm64-../../../.ssh.zip", nil),
    ("binary-macos-arm64-..%2F..%2F.ssh.zip", nil),
    ("binary-macos-arm64-1.0..2.zip", nil),
    ("binary-macos-arm64-a%2Fb.zip", nil),
    ("binary-macos-arm64-.zip", nil),
]
for (name, want) in versionCases {
    let got = extractVersion(from: URL(string: "https://sdk-assets.browserstack.com/" + name)!)
    if got == want {
        print("ok    version \(want.map { "'\($0)'" } ?? "rejected") '\(name)'")
    } else {
        print("FAIL  version want \(want ?? "nil"), got \(got ?? "nil") '\(name)'")
        failures += 1
    }
}

// RedirectPolicyDelegate applies the policy to every redirect hop: it must forward an
// allowed https target and veto (hand back nil) anything else. The task is never resumed,
// so nothing touches the network.
private let delegate = RedirectPolicyDelegate()
let session = URLSession(configuration: .ephemeral)
let task = session.dataTask(with: URL(string: "https://api.browserstack.com/sdk/v1/download_cli")!)
let redirectCases: [(String, Bool)] = [
    ("https://sdk-assets.browserstack.com/cli/binary-1.2.3.zip", true),
    ("https://browserstack.com/cli.zip", true),
    ("http://sdk-assets.browserstack.com/cli/binary-1.2.3.zip", false),
    ("https://evil.example/cli.zip", false),
    ("https://evilbrowserstack.com/cli.zip", false),
    ("https://browserstack.com.evil.example/cli.zip", false),
    ("file:///tmp/cli.zip", false),
]
for (target, wantFollow) in redirectCases {
    let response = HTTPURLResponse(
        url: task.originalRequest!.url!, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target])!
    let newRequest = URLRequest(url: URL(string: target)!)
    var followed: URLRequest?? = .none
    delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                        newRequest: newRequest) { followed = .some($0) }
    guard case .some(let next) = followed else {
        print("FAIL  redirect callback never called for '\(target)'")
        failures += 1
        continue
    }
    let didFollow = next?.url == newRequest.url
    if didFollow == wantFollow {
        print("ok    redirect \(wantFollow ? "follow" : "veto") '\(target)'")
    } else {
        print("FAIL  redirect want \(wantFollow ? "follow" : "veto"), got \(didFollow ? "follow" : "veto") '\(target)'")
        failures += 1
    }
}
task.cancel()

let total = cases.count + versionCases.count + redirectCases.count
print("\(total - failures)/\(total) passed")
exit(failures == 0 ? 0 : 1)
SWIFT
} > "$WORK/policy.swift" || exit 1

swiftc -o "$WORK/policy" "$WORK/policy.swift" && "$WORK/policy"
