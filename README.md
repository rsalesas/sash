# Sash

A Swift package that hosts a single-page web app as a native macOS app. Your
SwiftUI, your windows, your menus; the web app in a view; extensions as the
only door between them.

```swift
import Sash
import SwiftUI

@main
struct WorldClockApp: App {
    @State private var host = Sash.Host(web: .bundle(.main, subdirectory: "web")) {
        Clipboard()
    }

    var body: some Scene {
        WindowGroup { SashView(host) }
        Settings { ClockSettings(settings: host.store.scope("settings")) }
    }
}
```

The page is served at `sash://app/` from a private scheme, talks HTTP and a
small `window.sash` object, and can reach nothing Swift did not declare.

## What you get

- **A view.** `SashView(host)` anywhere a SwiftUI view goes, as many times as
  you like. Each one is a session with its own web view, context and event
  stream; the host, store and extensions are shared.
- **Routes.** `fetch("/api/...")` from the page can be answered by Swift, with
  streamed bodies so Server-Sent Events work.
- **Calls.** `await sash.clipboard.writeText({ text })`. The function table is
  generated from what extensions declared; an unknown namespace rejects with
  `capability-missing` instead of being `undefined`.
- **State.** One store, scoped, persisted in `UserDefaults`. `localStorage`
  in the page is backed by it, the Settings window binds to it, and changes
  reach every window live.
- **Context.** The page reports its title and the commands it handles;
  toolbars and menus read that from `host.focused?.context`.
- **Network policy.** Without the `Net` extension the page has no network.
  With it, the allow list is the only policy: it drives both the proxied
  `sash.net.fetch` and WebKit's own rule list for the page's `fetch`.

- **Sources.** The page can come from the bundle, a directory, a unix-socket
  backend, a local HTTP port, a dev server with live reload, or layers of
  those.
- **Updates.** An app channel (appcast, verified against the running app's
  own code-signing requirement, swapped and relaunched) and a web channel
  (an Ed25519-signed manifest downloaded into an overlay, probed in a hidden
  session and rolled back if the page never becomes ready).

Standard extensions are deliberately three: state (core), `Net`, `Clipboard`.
Everything else is a small extension you write; see the recipes in
[docs/spec.html](docs/spec.html).

## Adding it

```swift
.package(url: "https://github.com/rsalesas/sash.git", from: "0.1.0")
```

macOS 15 or later, Swift 6. No dependencies.

## Examples

`Examples/Calculator` is the smallest app: a page in a window, core only.
`Examples/WorldClock` persists cities through the store, binds a Settings
window to the same store, and drives a toolbar and menu from context.

```bash
Examples/build-examples.sh
```

needs [xcodegen](https://github.com/yonaskolb/XcodeGen).

## Tests

```bash
swift test
```

Unit tests need nothing. The integration tests boot real pages in offscreen
windows and skip themselves when there is no window server.

## Releasing a web layer

```bash
swift Tools/sash-web-release.swift keygen
swift Tools/sash-web-release.swift manifest path/to/web --version 1.2.0 \
  --base https://cdn.example.com/app/web/1.2.0/ --key <private-key>
```

Embed the public key in `UpdateConfiguration.WebChannel`, upload the files
under `--base`, and put `manifest.json` and `manifest.json.sig` where the
channel's `manifestURL` points.

## Docs

- [docs/spec.html](docs/spec.html): the contract, decisions and recipes.
- [docs/spec-android.html](docs/spec-android.html): the same contract, on Android.
- [docs/brainstorming.html](docs/brainstorming.html): where it came from.
