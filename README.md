# SpeakerPrep

## Building & Distribution

Outside the App Store, no sandbox. For now: bump the version (target > General >
Identity: Build for every new archive, Version when the release is meaningful),
then Archive, Distribute App, Custom, Copy App, signed with the free Personal
Team, zipped. Other Macs must allow it once in
System Settings > Privacy & Security (Open Anyway). Developer ID + notarization
removes that step when a paid account is worth it; nothing else changes.
Hardened runtime is already on because notarization will require it; the app
needs no exception entitlements. If an AUv2 plugin ever fails to load under
library validation, the fix is com.apple.security.cs.disable-library-validation.
