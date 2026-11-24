# Resolved issues

History of what was found and how it was settled. Open items are in
`../issues.md`. Style and error-handling issues excluded.

## HardwareService.swift

1. [x] **`layout.left` double-converted to stream-relative (startTap:561-573).** `makeTapLayout` already subtracts `outputStream.lo`, then `startTap` bounds-checks the relative `left` against absolute `lo`/`hi` and subtracts `lo` again. Any stream with `lo > 0` fails the guard; if it passed, `leftBufferIndex` would be negative. Only works for the first stream. — fixed: guard is now `0 <= left && left+1 < (hi - lo)`, `leftBufferIndex = layout.left`.

2. [x] **Interleaved tap format not rejected (540-549).** Message said "non-interleaved" but `kAudioFormatFlagIsNonInterleaved` is never checked. — fixed by correcting the message: interleaving of the tap format is irrelevant, since the callbacks see `deviceASBD` (explicitly non-interleaved) as the output unit's client format and AUHAL converts.

3. [x] **`makeStream` underflows (366).** `Int(firstChannel - 1)` on `UInt32`; a `kAudioStreamPropertyStartingChannel` of 0 traps/wraps. Per `AudioHardwareBase.h` ("the first element in the owning device that corresponds to element one of this stream"; stream/device elements are numbered from 1, element 0 is the main element) the documented domain is >= 1, so only a non-conforming driver underflows. — fixed: `firstChannel != 0` guard. Note this now routes a bogus driver into #4/#12 (whole device list becomes `nil`, `evaluate()` bails).

4. [x] **`currentHardwareDevices` is all-or-nothing (290-299).** One unreadable device (no UID/name/streams) returns `nil` for the whole list, which aborts `evaluate()` entirely. — fixed: bad devices are now skipped with `continue`. Two knock-ons: (a) if *every* device fails, the result is `[]` rather than `nil`, so `evaluate()` proceeds and stops the tap instead of bailing (better, but see #13); (b) a whole-list read failure at 279-286 still returns `nil`, so #12 stands.

5. [x] **Effect render resources never released.** `startTap` calls `effectUnit.allocateRenderResources()`; `stopTap` never calls `deallocateRenderResources()`. Tap restart with the same effect re-allocates on an already-allocated unit. — fixed: `stopTap` takes the unit, nils `effectRenderBlock`, then deallocates. Teardown order is correct (stop/uninit output unit → drop block → dealloc AU resources → free buffers). See #26 for a hazard the new signature introduces.

6. [x] **`stopTap` frees effect buffers before disposing the output unit (926-950).** Buffers referenced by the render callbacks are deallocated while the unit still exists; also `effectRenderBlock`/`effectUnit` are left live until `deinitialize`. — fixed: stop/uninit/dispose are now one block (918-923) ahead of the render-block/AU teardown and the buffer frees, so nothing that can dereference `tapPtr` outlives it.

7. [x] **Allocation on the render thread (outputCallback:179-197).** `pullInputBlock` closure is heap-allocated every render cycle, and reading `effectRenderBlock`/`effectUnit` out of `Tap` does ARC traffic. Not realtime-safe. — fixed: block is built once in `startTap` (captures `refCon`, stored in `Tap.pullInputBlock`, cleared in `stopTap`) and pulled out of the existing guard in `outputCallback`. Residual retain/release when binding the two blocks from `tapPtr.pointee` is atomic-only, no allocation.

8. [x] **`zeroList` is a no-op on null buffers (effectCallback:47, 56).** On the early-out paths, if the AU handed us `mData == nil` we return silence flags but leave the AU's buffers unwritten/unassigned, so it may read uninitialized memory. — fixed: paths are now split by return code. Error returns (too many frames, no buffers) leave `ioData` alone since the AU must abort; the `mData` materialization is hoisted above every `noErr` path, so the silence path zeroes real memory.

9. [x] ~~**`copyChannel` shrinks `mDataByteSize` (250).** Writes back `n + tail`, permanently narrowing CoreAudio-owned output buffers when the source is short.~~ **Wrong as originally written.** `n + tail == min(size, dstSize)`; a short source zero-fills the remainder and still reports `size`, and lowering an oversized `dstSize` to `size` is the correct output convention. The real defect in these two functions was that a declared `mDataByteSize` of 0 with non-null `mData` means "unspecified", not "empty", so both truncated the cycle to silence and latched the 0. — fixed via `channelByteSize`, which falls back to `size` when the declared value is 0. Also folded in `0 <= index` bounds checks (see note under #25).

10. [x] **Aggregate channel layout assumption (742).** Tap channels are assumed to be appended after all hardware inputs, and exactly one tap is assumed. Only guarded by a count equality check. — empirically confirmed on a 24-in/24-out interface: the aggregate's input streams are the hardware stream at channel 1 and the tap stream at channel 25. Still an assumption, but a verified one.

11. [x] **`instantiateEffect` (was `initEffectUnit`) blocks on a semaphore (1001-1021).** `AVAudioUnit.instantiate` may complete on the main queue; deadlocks if ever called from main. — resolved as a design decision: the SDK headers say the completion runs on an arbitrary thread and warn only against blocking *main*; the state machine's queue is not main, so the synchronous wait is correct and keeps evaluate() settled on return. Residual: quitting mid-load can hit `shutdown()`'s 2s timeout, which is bounded and cosmetic. The real gap behind this issue was UX (nothing visible during a slow load), fixed by publishing `EffectStatus.loading` before the call and `.ready`/`.failed` after, with the view disabling dependents and showing a spinner. See architecture.md §Status.

## StateMachine.swift

12. [x] **`evaluate()` bails out and leaves the tap running (188-200).** If `currentHardwareDevices()` returns `nil` or `currentEffects()` is empty (both plausible when the device disappears), it returns early, so a tap on dead hardware is never torn down.

13. [x] **`makeTapLayout` collapses every failure into one `nil`.** The stop-vs-invalid half is handled: `fail()` only records a failure when `desiredConfig.isTapping`, so stopping no longer reads as failing. What remains: incomplete config, device vanished, no stream holds the pair, and effect missing are all the same `nil` and all surface as "The tap is not fully configured" (unplugging the interface mid-tap reads as misconfiguration), and nothing retries after a transient enumeration failure until the next event. Returning a reason (enum/`Result`) would fix the message and drop the `print` on the ordinary not-yet-configured path. — fixed: returns `LayoutResult` (`.ready` / `.incomplete` / `.unavailable(message)`); the stop check moved up into `evaluate()` where it belongs. Retry-after-transient-failure is covered by #15.

14. [x] **`setDesiredConfig` replaces instead of merges.** `Config` fields are optional and the comment says "merged with existing desired state", but the whole struct is overwritten, so partial configs clear prior selections.

15. [x] **Hardware listeners only exist while tapping (startTap:894-899).** No tap means no `onHardwareChange`, so a desired device that appears later never triggers a start, and device list changes go unnoticed. Worse, listeners are registered at the very end of `startTap` and removed in `stopTap`, so when `startTap` *fails* (sample-rate mismatch, device busy) there are no listeners and fixing the cause never retries; the user has to toggle. Suggested: `StateMachine` owns the `kAudioHardwarePropertyDevices` listener for its lifetime and publishes the device list (also fixes #21); the tap keeps the device-specific sample-rate/is-alive listeners. — fixed, going further than suggested: `StateMachine` owns both. The device-list listener lives in `init`/`deinit`; the device listeners are reconciled in `evaluate()` via `watchDevice(uid)` against the desired device, whether or not a tap is running. `Tap` no longer has `onChangeBlock` and `startTap`/`stopTap` no longer take a queue or callback. `HardwareService` exposes `listenForDeviceList` / `listenToDevice` / `stopListening` over a `HardwareListener` handle. Device list is not yet published to the view (#21).

16. [x] **Effect lifetime is not tied to the tap.** `isTapping = false` stops the tap but leaves the effect instantiated; the effect only stops when its ID changes. — resolved as a design decision, not a fix: the effect deliberately outlives the tap so plugin parameters persist across device/channel changes and tap restarts (see architecture.md). The render-resourced half is gone since `stopTap` now deallocates render resources (#5).

17. [x] **`stopEffect` doesn't release the unit.** `effect = nil` only drops the reference; no `deallocateRenderResources`, and the UI window may still hold `auAudioUnit` (see #20). — fixed: `stopEffect` always goes through `stopTap`, which deallocates render resources (#5), and `ContentView` closes the window on `publishedEffect?.effectID` change (#20). Only the "verify this isn't leaking" TODO remains.

18. [x] **`publishedIsTapping`/`publishedEffect` lag the desired state.** Updates hop to main asynchronously, so `toggleTap` can compute a stale `!publishedIsTapping` and enqueue a duplicate start/stop. — fixed: `ContentView` keeps its own `isTapping` intent state and `toggleTap` flips that; `publishedIsTapping` is gone, replaced by `publishedStatus`, which is display-only.

## ContentView.swift

19. [x] **`availableLefts` recomputes channel bases (28-38).** Accumulates `channelsSeen` instead of using `stream.lo`, but `Config.left` is device-absolute and matched against `stream.lo/hi`. Diverges whenever stream ranges aren't contiguous from 0. Also ignores `stream.lo` parity.

20. [x] **`windowController` is cached for the first effect only (135-143).** Created when `nil`, so after the effect changes the window still hosts the old `auAudioUnit`; it is also not closed when `publishedEffect` becomes `nil`.

21. [x] **Devices/effects loaded once (91-99).** `loadDevicesAndEffects` only fills empty arrays and nothing observes hardware changes, so `deviceIndex`/`effectIndex` can index a stale snapshot that no longer matches what `evaluate()` sees. — fixed: `StateMachine` publishes `publishedDevices`/`publishedEffects` from every `evaluate()` (and runs one on `init` to populate them), and `ContentView` selects by `uid`/`effectID` instead of index, so there is no snapshot to go stale. If the selected device disappears the selection is kept as intent (picker shows blank, status says the device is unavailable) so the tap resumes when it returns.

22. [x] **`isStartDisabled` is never used.** The Start/Stop button is always enabled, so it can send a config with `nil` device/channel/effect, which `makeTapLayout` silently rejects.

23. [x] **Changing pickers while tapping does nothing.** No `onChange` pushes new selections to the state machine; the UI can show a device/channel/effect different from the running tap until the button is pressed. — fixed: every picker has `.onChange → sendConfig()`.

24. [x] **Teardown relies on `onDisappear` (100-104).** On app quit this may not run, leaking the process tap and the private aggregate device in CoreAudio.

25. [x] **`startTap()` is dead code (124-132).**

## Introduced by fixes

26. [x] **`StateMachine.stopTap` silently no-ops when the effect is missing (284-291).** The new `guard let p = tapPtr, let e = effect, let avUnit = e.avAudioUnit else { return }` bails out on three unrelated conditions. The `tapPtr != nil implies effect != nil` invariant holds today (`stopEffect` stops the tap before clearing `effect`), but if it is ever broken the tap is neither torn down nor freed: the process tap, aggregate device, output unit and `tapPtr` all leak with no diagnostic. `Tap.effectUnit` already stores the unit, so `HardwareService.stopTap` could read it from `tapPtr` instead of taking it as a parameter that the caller has to re-derive. — fixed: signature reverted to `(tapPtr, queue)`, guard back to `tapPtr` only, teardown uses `tapPtr.pointee.effectUnit?.deallocateRenderResources()`.

## StateMachine review (alpha pass)

27. [x] **`fail()` doesn't enforce that the tap is stopped.** Overwrote `tapState` without checking for `.running`, which would leak the `Tap` pointer if a caller forgot `stopTap()` first. — fixed: both `fail()` and `startTap()` now call `stopTap()` first, so no transition can overwrite or double-start a running tap; `evaluate()` drops the redundant `stopTap()` calls before them.

28. [x] **`.starting` is published on every `setDesiredConfig` with `isTapping`.** Including no-ops and effect-only swaps, so the UI flickers "Starting… → Tapping" for changes that didn't restart anything. Pressing Start with an incomplete config lands on "Failed: not fully configured"; either disable Start until the config is complete or add a waiting-for-config status. — fixed with #11: `.starting` is published inside `startTap` just before the blocking call, and Start is disabled until the config is complete and the effect is ready.

29. [x] **`StateMachine.deinit` doesn't tear down a running tap.** Dropping the machine while tapping leaked the `Tap` pointer and left CoreAudio running. — fixed: `deinit` now calls `HardwareService.stopTap(p)` directly when `tapState` is `.running(p)`. No `queue.sync` (and thus no deadlock): ARC guarantees exclusive access during `deinit` and `HardwareService.stopTap` does not depend on `queue`.

30. [x] **`guard !effects.isEmpty` tears down the live effect.** Original framing was backwards against the design principle: the state machine rules in all circumstances, so if an observed effect list no longer contains the running effect, tearing down the effect (and stopping the tap) is the right behavior. What was actually wrong: the guard only caught an empty list (not a single missing effect) and returned early before `watchDevice`/`publishedDevices`. — fixed: replaced `guard !effects.isEmpty` with `isCurrentEffectAvailable(in: effects)`, so any missing running effect triggers `stopEffect()` (and `startEffect` records `.failed`) while device reconciliation still runs; also dropped the redundant `effects` parameter from `makeTapLayout`.

## TODOs moved out of source

32. [x] **Save and load app/effect settings.** Nothing is persisted; device, channels, effect, and plugin state are lost on quit. — fixed: `SettingsService` over UserDefaults. Selections are saved on every `sendConfig()` and restored into the view's initial state; AU `fullState` is keyed per `EffectID`, restored after instantiate, and saved in `stopEffect` (option A: lifecycle boundaries only, so a crash loses parameter tweaks since the last effect change). A saved `isTapping` auto-starts on launch. Deferred: saving AU parameters on every change would need a parameter observer plus a debounce timer. See architecture.md §Settings.

## Found while testing

31. [x] **AU busses disabled, effect renders silence.** `AVAudioUnit.instantiate` returns an `AVAudioEngine` node whose busses are only enabled when the engine connects them. Driven directly via `auAudioUnit`, the effect pulls input and returns `noErr` but writes nothing. Diagnosed by logging per-channel peaks at each stage: tapped audio reached `effectCallback` and was delivered to the AU, but `inputBusses[0].isEnabled` and `outputBusses[0].isEnabled` were both false. — fixed: `startTap` sets both to `true` after `setFormat`, before `allocateRenderResources`. Keeping `AVAudioUnit` (rather than `AUAudioUnit.instantiate`, which also loads v2 and v3) is deliberate: `.audioUnit` is the only public route to the v2 handle needed for an `AUGenericView` fallback. See architecture.md.

35. [x] **Unwanted muting when switching devices** (e.g. Bluetooth headphones while tapping the interface). Root cause: in `coreaudiod`, `CATapMuteBehavior.mutedWhenTapped` on an `isExclusive = true` tap mutes all matched processes across *every* device once any process is active on the tapped device. — fixed: switched to an inclusive tap (`isExclusive = false`) of only processes whose output `kAudioProcessPropertyDevices` contains the target device (excluding our own PID). While tapping, `StateMachine` watches `kAudioHardwarePropertyProcessObjectList` and per-process output devices and updates `kAudioTapPropertyDescription` in place without restarting the tap. Follow-up catch: `coreaudiod` doesn't preserve array order in `CATapDescription.processes`, so `updateTapProcesses` compares as `Set` and `startTap` seeds `tappedProcesses` to avoid a redundant write racing with `HALB_IOThread::_Start`. Known OS limit: a single process outputting to two devices at once would still have both muted.

36. [x] **Echo with Ableton Live** when tapping channels 1-2 while Live outputs to 3-4. — resolved by #35's switch from an exclusive tap to an inclusive per-device process tap; verified clean with Live open on 3-4 and tap running on 1-2.

38. [x] **Bring code in line with `swift_rules.md`.** — fixed: marked `StateMachine` `final`, changed `ContentView.availableLefts` to a method `availableLefts() -> [Int]`, and flattened `e.avAudioUnit?.auAudioUnit.fullState` in `stopEffect()`.

39. [x] **Tighten `Config` and queue preconditions.** — fixed: changed `Config.isTapping` from `Bool?` to `Bool` (removing `?? false` across `StateMachine`, `ContentView`, and `SettingsService`), and added `dispatchPrecondition(condition: .onQueue(queue))` to `startEffect`, `stopEffect`, and `isCurrentEffectAvailable`.

41. [x] **Host-side effect bypass.** — implemented with C11 `<stdatomic.h>` acquire/release helpers in `src/AudioAtomics.h` (bridging header, keeping macOS 14.2 target), warm bypass (keeps `effectRenderBlock` fed while discarding output when dry so un-bypassing has no click/pop), and a 15ms equal-power dry/wet crossfade (`mixChannel`) in `outputCallback`. Persisted in `SettingsService`, toggleable at any time, kept off `TapLayout` so toggling never restarts the tap. Menu bar icon: `circle.inset.filled` when active, `smallcircle.filled.circle` when bypassed.

42. [x] **Mono-only plugins appear in the Effect picker and fail at Start.** — fixed: `HardwareService.currentEffects()` now filters via `component.supportsNumberInputChannels(2, outputChannels: 2)`, keeping dual-mode plugins in stereo and excluding strictly mono-only plugins.
