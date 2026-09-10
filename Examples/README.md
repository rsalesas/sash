# Examples

Each example is an xcodegen project depending on the package by local path.
Run `./build-examples.sh` to generate and build both, or open a generated
`.xcodeproj` after `xcodegen generate` inside the example's folder.

| App | Shows |
|---|---|
| Calculator | The smallest Sash app. No extensions; the page uses `--sash-accent` and reports its title. |
| WorldClock | `localStorage` backed by the store and surviving relaunch; a SwiftUI Settings window bound to the same store; a toolbar and a `Clock` menu enabled from the page's context and delivered as commands; the `Clipboard` extension. |

Debug builds are ad-hoc signed and not sandboxed, because WebKit's content
process crashes under App Sandbox with an ad-hoc signature. Release builds
of a real app should sandbox and sign properly.

The web folders are plain HTML, CSS and JavaScript with no build step, and
both pages run unchanged in a browser (with Sash features absent).
