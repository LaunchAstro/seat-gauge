# SwiftPM on Command Line Tools only, fonts copied by script, ad-hoc signed as one unit

The app builds without Xcode. It is a plain `Package.swift` built with `swift build -c release`, assembled into `Seat Gauge.app` by `scripts/build-app.sh`, and signed ad hoc with `--identifier com.launchastro.seatgauge` to match `CFBundleIdentifier`. That match is what lets `UNUserNotificationCenter` and `SMAppService` work on an ad-hoc signature.

Fonts are copied into `Contents/Resources/Fonts` by the script and registered at launch from `Bundle.main`. SwiftPM's `resources:` accessor for an executable target looks beside the bundle and at the absolute build path, never inside the bundle, so an installed copy crashed on the first font lookup.

`swift test` needs three extra framework and rpath flags on the Command Line Tools, because Swift Testing ships there and XCTest does not. They live in the `Makefile`.
