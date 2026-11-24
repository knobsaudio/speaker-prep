Everything about this project is low-key/minimalist including the docs, but we
want the underlying behavior to be bulletproof and the code to be readable (good
names and scopes).

## Pieces

SpeakerPrepApp owns everything app-level: the StateMachine, the first config
send at launch, shutdown on willTerminate, the plugin window controller, and
the menu bar icon. StateMachine and HardwareService know nothing about the
application. ContentView is the dropdown's form; it outlives nothing.

ContentView     => StateMachine    "Here's what I want" (Config)
StateMachine    => ContentView     "Here's what's happening" (TapStatus, Effect)
StateMachine    => HardwareService list devices/effects, make effect, start/stop tap
HardwareService => StateMachine    "hardware changed" (listener pings reevaluate)

## Threads

- main: UI only.
- StateMachine's serial queue: evaluate(), all CoreAudio setup/teardown,
  hardware-change listeners.
- realtime audio thread: outputCallback/effectInputCallback. No allocation, no locks,
  no ARC — hence Tap is a heap struct behind an UnsafeMutablePointer.

## StateMachine

On any config or hardware change, evaluate() runs on the private queue: "Look at
what the user wants. Look at what I have. Fix the difference." The state machine
rules in all circumstances: anything currently running (effect or tap) that is no
longer present in what evaluate() observes is torn down. Results are published
back to the main queue.

Config is raw user intent (may be incomplete, channel index is device-relative).
makeTapLayout() resolves it into a validated TapLayout (stream-relative), or says
why it can't (incomplete vs. unavailable, with a user-facing reason). A tap is
rebuilt only when the running tap's layout != the desired layout.

StateMachine owns hardware awareness, not the Tap: a device-list listener for
its whole lifetime, plus sample-rate/is-alive listeners on the desired device,
reconciled in evaluate() like everything else. So a tap that failed to start
still retries when the hardware changes. While a tap is running, it also watches
the audio process list and each process's output devices, updating the live tap's
process list in place via kAudioTapPropertyDescription without restarting the tap.

The effect (AVAudioUnit) outlives the tap: it's created when the user picks it and
survives tap restarts, so plugin parameters persist across device/channel changes.
startTap only allocates its render resources.

The effect is instantiated via AVAudioUnit (not AUAudioUnit) so that .audioUnit,
the v2 handle, stays available for an AUGenericView fallback. There's no
AVAudioEngine, so startTap enables the busses manually.

Ordering (first version): the effect must be ready before a tap starts, and the
tap must be stopped to change the effect or device/channels. Loading blocks
whatever depends on it, which the serial queue gives for free; the instantiate
wait is synchronous by design (the SDK warns only against blocking main).

## Settings

UserDefaults via SettingsService. Each layer persists what it owns: the view
saves the selections (device, channels, effect, isTapping) in sendConfig() and
seeds its @State from them in init; the machine restores the AU's fullState in
startEffect and saves it in stopEffect (so quit and effect switch both save).
shutdown() bypasses sendConfig so its empty config is never persisted. A
saved isTapping restarts the tap on launch through the normal path.

## Status

Effect and tap each publish their own status (EffectStatus, TapStatus). Loading
and starting are published just before the blocking call and never stored, since
by the time evaluate() returns they are over. The view disables what depends on
an in-progress step, shows a spinner, and shows success or failure, so the user
always knows why nothing is happening.

## Menu bar

MenuBarExtra in window style, LSUIElement so there's no Dock icon; the icon is
a record-style inset circle (circle.inset.filled) while tapping, a small-center
target circle (smallcircle.filled.circle) while tapping and bypassed, and an
outlined square otherwise (a speaker glyph was confused with the system's). The plugin window is owned by the app so it survives the
dropdown closing. It opens when the dropdown opens with a ready effect, or when
the effect becomes ready while the dropdown is visible; never at launch. It
closes when the effect goes away or the user closes it. Launch at login uses
SMAppService, so the user can also change it in System Settings; the toggle
re-reads the status each time the dropdown opens.

## Tap setup (HardwareService.startTap)

- Create a process tap on the target output stream. Inclusive (isExclusive =
  false) of only processes currently outputting to the target device (excluding
  our own PID), with mutedWhenTapped so the original audio is silenced. An
  exclusive tap leaks mute across all devices in coreaudiod once any process is
  active on the tapped device (e.g. muting Bluetooth headphones).
- Create a private aggregate device that bundles the real device + the tap, so the
  tap's channels show up as extra inputs on the aggregate (assumed to be last).
- Create a HAL output unit on the aggregate. Formats are float, non-interleaved,
  full channel count of the tapped stream. Channel maps say "read input from the
  tap channels, write output back to exactly the stream we tapped, -1 elsewhere".
- Allocate stereo scratch buffers, set the effect's busses to stereo float, hook
  up callbacks.
- Start it.

## Render cycle (realtime)

The tap is always a stereo pair. If the tapped stream has more channels the rest
are passed through by memcpy.

CoreAudio: "Give me N frames for all output channels" (outputCallback)
  - AudioUnitRender(input bus 1) pulls the whole tapped stream into ioData.
    Non-target channels are now already in place and pass through untouched.
  - effect.renderBlock(effectOut buffers, pullInputBlock) — runs even while
    bypassed (warm bypass) so un-bypassing has no stale filter state or
    sample-time jump.
    - Effect: "I need my input" (effectInputCallback)
      - copies target L/R from ioData into the effect's input.
    - Effect writes processed L/R into effectOut.
  - Check atomic bypass flag (src/AudioAtomics.h). If bypassed and fully dry,
    return immediately (discard effectOut, leaving dry L/R in ioData). If fully
    wet, copy effectOut over target L/R; if transitioning, crossfade dry/wet
    with a 15ms equal-power curve. If the effect errored, leave the untouched
    pass-through; if it flagged silence, zero the pair.
  - "done" — ioData goes to the speakers.
