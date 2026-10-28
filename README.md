# Mic Lock

A small native macOS menu bar app that keeps your preferred microphone as
the default input. Built with Swift, AppKit, and CoreAudio, with no third-party
dependencies. The app's menu is currently in Portuguese.

## Usage

1. Build the app with `./scripts/build.sh`.
2. Open `build/Mic Lock.app` (or run `open "build/Mic Lock.app"`).
3. Click the microphone icon near the clock and choose your preferred input.
4. Leave the microphone lock toggle enabled.

On first launch, the app waits for your selection without changing the current
microphone. A checkmark identifies your preferred input, while a separate status
line shows the actual default input. Your selection and pause state persist
between launches.

If the microphone disconnects, the app waits and lets macOS use another input.
When the device returns, the app attempts to restore it as the default. The
selection is stored by device UID. If a driver changes that identifier, such as
after an update or a port change for a device without a serial number, select
the microphone again. Duplicate device names are numbered in the menu, and each
item's tooltip shows its full identifier.

Disable the lock toggle to use another input temporarily. If another app keeps
changing the default input or the audio system encounters errors, Mic Lock
limits its correction attempts and offers a retry action. During normal
operation, it responds to audio events without polling.

## Launch at Login

Move the app to a stable location, such as `~/Applications`, before enabling
the launch-at-login option. This uses native macOS registration and is disabled
by default. If approval is pending, click the option to open System Settings.
Disable launch at login before moving or deleting the app.

Quitting Mic Lock stops enforcement and leaves the current input unchanged.
If launch at login is enabled, that registration remains active for your next
login. Automatic restart after a process crash is not guaranteed.

## Build and Test

Requires macOS 13 or later and Xcode or Command Line Tools with Swift 6 or
later. The build targets your Mac's current architecture.

```sh
./scripts/test.sh
./scripts/build.sh
"build/Mic Lock.app/Contents/MacOS/MicLock" --diagnose
"build/Mic Lock.app/Contents/MacOS/MicLock" --smoke-test
```

`--diagnose` lists available inputs and identifies the current default.
`--smoke-test` creates the menu with empty temporary preferences, prints its
contents, and exits. Neither command changes the microphone or registers the
app to launch at login. The smoke test requires an available graphical session.

The bundle is ad hoc signed for local use and is not notarized for
distribution. Open `Package.swift` to work on the project in Xcode.

## Scope and Limitations

Mic Lock manages the default macOS input. Apps with an explicitly selected
microphone must be configured to use the system default. Corrections happen
after a CoreAudio notification, so a brief initial switch can still occur.
An ongoing call is not guaranteed to follow the restored default. The app does
not capture audio or request microphone recording access.

Automated tests verify the locking policy without changing real audio devices.
Physical microphone reconnection and behavior during calls require separate
manual verification.
