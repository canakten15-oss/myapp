# Contributing

Thanks for helping. Rules:

1. **Nothing may be lost.** Any change that touches saving or deleting needs a test on a real device using the checklist in `docs/ARCHITECTURE.md`.
2. **On-device only.** No network calls except the ad SDK.
3. One feature or fix per pull request, with a short description and before/after sizes for compression changes.
4. Use Swift 5 language mode, SwiftUI and the system frameworks. No new dependencies without discussion.

## Setup
```bash
brew install xcodegen
xcodegen generate
open MyApp.xcodeproj
```

## Reporting bugs
Open an issue with: iPhone model, iOS version, video source (iPhone camera/WhatsApp/other), resolution, HDR yes/no, and what went wrong. Never attach private videos.
