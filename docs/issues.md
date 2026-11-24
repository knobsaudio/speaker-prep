# Open issues

Resolved history lives in `done/issues.md`. Numbers continue from there.

## Open questions

33. [ ] **Debounce `evaluate()`?** Hardware listener storms rescan devices and effects on every event even though layout equality makes the extra runs no-ops.

34. [ ] **Can `HardwareService.stopTap` fail?** Teardown currently logs and ignores errors from `AudioHardwareDestroyProcessTap` and `AudioHardwareDestroyAggregateDevice`.
