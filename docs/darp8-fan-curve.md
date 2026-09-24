# darp8 fan curve (branch `my-darp8-fan-curve`)

## TL;DR

Stock darp8 fan curve is fully off below 70°C and has no explicit top point
(above 90°C it silently falls through to 100% duty), so the fan is either
silent or abruptly loud. This branch adds a quiet always-on floor and widens
the ramp toward the CPU's real thermal ceiling so the loud transition is
gradual instead of a jump.

This branch is **not** built on top of upstream `master`. It's built on the
exact commit that produced this specific laptop's currently-installed,
released firmware (tagged `darp8`, see below), because upstream `master` has
138 unrelated commits since then — including an unresolved bug we hit when
testing the same curve change there (see "What went wrong on `master`, and
why we didn't chase it there" below).

The only functional change is `src/board/system76/darp8/board.mk`'s
`BOARD_FAN_POINTS`. `scripts/build-in-docker.sh` was added to make that
buildable at all (see "Toolchain trap" below).

Verified on real hardware: idle floor holds at a steady, confirmed-inaudible
~1400 RPM; forced 100% duty reads ~8700-8900 RPM (matches pre-change
baseline); a full ~19-minute real build (cleanroom + integration tests)
cycling repeatedly through 65-96°C showed RPM tracking temp/duty correctly
throughout, no anomalies.

## Build & flash

```sh
# From the repo root, on this branch:
git checkout my-darp8-fan-curve

# Build (runs in a disposable ubuntu:22.04 container; see "Toolchain trap")
./scripts/build-in-docker.sh
# -> build/ec.rom

# Flash (needs cargo/rustc/libhidapi-dev/pkg-config on the HOST, for tool/;
# these are unrelated to the SDCC issue below and fine to build natively)
make BOARD=system76/darp8 flash_internal
```

`flash_internal` will:
1. Build `tool/` (the flashing CLI) with `cargo`.
2. Prompt for `sudo`.
3. Print the file's and the EC's current board/version strings — it aborts
   before touching anything if the board string doesn't match.
4. Wait 5s for keys to be released.
5. Read the *entire current chip contents* and save them to `backup.rom` in
   the repo root — **automatic, unconditional, happens before any write**.
6. Write the new image, then re-read and verify every byte.
7. Hard power off after another 5s countdown. This is a forced EC watchdog
   reset, not a graceful shutdown — expect to need the power button to turn
   it back on (twice, in practice — see "Loose ends" below).

To revert: `sudo tool/target/release/system76_ectool flash backup.rom` (same
sequence, using the pre-flash dump instead of `build/ec.rom`). Note
`backup.rom` is a **fixed filename that gets overwritten on every flash** —
copy it elsewhere immediately if you want to keep a specific snapshot.

To check what's currently flashed: `sudo tool/target/release/system76_ectool info`.

## Why this branch is based on `01be30f1`, not `master`

There are **no tags and no GitHub releases** on `system76/ec` — nothing marks
what was actually shipped. The exact commit was derived, not guessed:

1. This laptop's real firmware version (`bios_version` in DMI, and the EC's
   own `system76_ectool info` output) is `2024-01-10_6c402c3`.
2. `6c402c3` doesn't exist in this (`ec`) repo — it's a
   [`firmware-open`](https://github.com/system76/firmware-open) commit:
   [`6c402c3e17`](https://github.com/system76/firmware-open/commit/6c402c3e17),
   "darp8,darp9: Use S0ix by default", which matches
   [`firmware-open`'s `CHANGELOG.md`](https://github.com/system76/firmware-open/blob/master/CHANGELOG.md)
   entry for darp8 on that exact date.
3. `firmware-open` vendors `ec` as a git submodule (see its
   [`.gitmodules`](https://github.com/system76/firmware-open/blob/master/.gitmodules)).
   That submodule's pin *at that exact commit* is an exact, non-guessable
   pointer: [`01be30f107c7930b0673d9f6a35058603f00bd63`](https://github.com/system76/ec/commit/01be30f107c7930b0673d9f6a35058603f00bd63).

That commit is tagged `darp8` in this local clone/fork so it doesn't rely on
reflog/dangling-commit survival:

```sh
git tag darp8 01be30f107c7930b0673d9f6a35058603f00bd63
```

**Do not rebase this branch onto `origin/master` or `dave/master`.** That
would silently reintroduce the 138-commit gap this branch exists to avoid,
including whatever actually caused the bug described below. Rebase onto the
`darp8` tag if you need to clean up history (`git rebase -i darp8`).

## What went wrong on `master`, and why we didn't chase it there

The same curve was first tried on top of upstream `master` (HEAD at the
time). It compiled and flashed fine, but forcing `fan_max` (100% duty,
which bypasses the curve entirely — see `fan_get_duty()` in
`src/app/main/fan/interp.c`) read back **~245 RPM** instead of the expected
~8700-8900. The user could audibly confirm the fan really was at max, so the
*duty control* was working — only the *RPM readback* was wrong, and only for
duty values in a range (~66-99%) the *original* 5-point curve had never
actually exercised (it only ever used 40-65%, then jumped straight to the
100% fallback).

That's suspicious but was never conclusively root-caused. Ruled out:
- A hardware PWM-polarity inversion — disproved by the fact that 100% duty
  gave the *highest* RPM reading under the pre-change curve's own fallback
  path.
- `interp.c` vs `step.c` mismatch with what darp8 actually shipped — checked
  darp8's real 2023-era `.interpolate` setting; it was also interpolating.

`master` has 138 commits since `01be30f1`, 63 of them touching
fan-relevant files, including several rewrites of exactly this control path
(`acpi: Report RPM values instead of raw tachometer values`,
`Refactor reading thermals, updating fan duty`,
`Sync fans based on temp instead of duty`, `fan: Remove HEATUP, reduce COOLDOWN`,
a full replace-then-re-add-then-redefault of the interpolation algorithm
itself). Building from the verified release commit instead — with *no other
change* — made the bug disappear (both the forced-max check and a full real
build now read correct, monotonic RPM values throughout). The exact
offending commit among those 63 was never identified; this branch sidesteps
the question rather than answering it.

## Toolchain trap: SDCC version matters here

Building `01be30f1` with a modern host SDCC (4.5.0, current Ubuntu) fails:

```
src/board/system76/common/smfi.c:244: error 110: conditional flow changed by optimizer: so said EVELYN the modified DOG
```

Line 244 is an ordinary bounded loop with a plain `if` — unrelated to
anything fan-related. This is a known class of SDCC optimizer regression
that varies by version, not a real code defect. This repo's CI at
`01be30f1` (`.github/workflows/ci.yml`) ran on `ubuntu-22.04`, whose `sdcc`
package is `4.0.0+dfsg-2` — a version this code was actually validated
against. `scripts/build-in-docker.sh` builds in a disposable
`ubuntu:22.04` container for exactly this reason, so nothing needs to be
downgraded on the host. It cleans `build/` first (a `build/` directory left
over from a different branch/commit has a different layout, and SDCC's
`-MMD` dependency files will reference paths that don't exist here,
producing confusing `No rule to make target` errors) and fixes file
ownership from inside the container before exiting (a plain host-side
`chown` after the container exits can't work — the host user doesn't own
the root-written files to begin with).

## Curve design notes

`src/board/system76/darp8/board.mk`:

```
CFLAGS+=-DBOARD_FAN_POINTS="\
	FAN_POINT(0, 20), \
	FAN_POINT(65, 20), \
	FAN_POINT(70, 30), \
	FAN_POINT(75, 40), \
	FAN_POINT(80, 50), \
	FAN_POINT(85, 62), \
	FAN_POINT(90, 75), \
	FAN_POINT(95, 90), \
	FAN_POINT(97, 100) \
"
```

Was: `(70,40) (75,50) (80,60) (85,65) (90,65)`, with an implicit 100% fallback
above 90°C (`fan_duty()` returns `MAX_FAN_SPEED` when no point matches).

- **`(0,20)`/`(65,20)` — the floor.** Two equal-duty points force a flat
  segment (`fan_duty()` only interpolates; there's no separate "minimum
  duty" concept in this era's code — the modern `CONFIG_FAN1_PWM_MIN`/
  `pwm_min` mechanism doesn't exist here at all). This is the same technique
  several other boards already used *higher up* their curves at this same
  commit (`oryp9`/`oryp10` use it three times each; `oryp11`, `gaze17-3050`,
  `serw13` use it once) — the mechanism is proven, but none of them push it
  down to near-idle the way this does; every other board's curve starts at
  50-70°C, so this is a genuinely new use case, not prior art.
- **`20` (duty%) is an informed guess, not a measurement.** There's no way
  to command an arbitrary duty pre-flash to find the real audible threshold
  (see "Why the floor value wasn't measured directly" below). An empirical
  proxy test (gradual single-thread load ramp with turbo disabled, user
  listening) put the audible onset somewhere at or under ~1500 RPM. Measured
  post-flash: this floor settles at a steady ~1400-1500 RPM, confirmed
  inaudible by the user. If retuning: adjust the `20` and reflash; there's
  also a real stall risk going *too* low (small fans often won't spin at all
  below some duty threshold — this hasn't been characterized either).
- **`90→97°C` is the other new part.** `temp1_crit` (real throttle/shutdown
  point, from `coretemp`) is 100°C, so 97°C/100% leaves 3°C of margin.
  Under a sustained real build this laptop routinely sits at 88-96°C for
  extended periods (not just brief spikes) — the old curve's implicit jump
  above 90°C wasn't an edge case, it was the routine case.

### Why the floor value wasn't measured directly

Two independent reasons neither this era's code nor the modern one allow
commanding an arbitrary duty from the host and having it stick:

- **This era** (`01be30f1`): `cmd_fan_set()` in `smfi.c` writes the `DCR2`
  register directly and unconditionally — but the 1-second `peci_get_fan_duty()`
  timer loop (also unconditional) overwrites it again on its own next tick.
  There's no `FanMode` concept at all yet (`CMD_FAN_GET`/`CMD_FAN_SET` are
  the only fan commands; `CMD_FAN_SET_MODE` doesn't exist until later
  upstream). This also explains why `system76_ectool fan_mode pwm` against
  this laptop's *actual currently-installed* firmware fails with
  `Protocol(1)`/`RES_ERR` — that command number simply isn't in this era's
  dispatch `switch`.
- **Modern `master`**: `FanMode`/`CMD_FAN_SET_MODE` exist, but
  `fan_get_mode() == FAN_MODE_AUTO` only gates the curve recompute for
  `CONFIG_FAN_CTRL_STEP` boards (`src/app/main/main.c`); `interp.c`'s
  `fan_event()` runs unconditionally every 100ms regardless of mode, so a
  host-commanded override gets stomped within ~100ms either way.

### Turbo/EPP context (not part of this change, but relevant if retuning)

Real package temp doesn't rise gradually with load on this CPU (12th Gen
Intel Core i7-1260P) — a single boosted core can spike it from ~65°C to
90°C+ within ~2 seconds, because `coretemp`'s "Package id 0" reads the
*max* of all per-core sensors. Disabling turbo
(`/sys/devices/system/cpu/intel_pstate/no_turbo`) makes load ramp genuinely
gradual (confirmed: 16 threads sustained at base clock only reached ~89-91°C
/ ~6000 RPM). GNOME's Power Mode (Power Saver/Balanced/Performance, via
`power-profiles-daemon`) does **not** meaningfully help here on this
hardware — it only sets `intel_pstate`'s EPP hint
(`energy_performance_preference`), which biases ramp *eagerness*, not the
turbo ceiling. `system76-power` is not installed on this machine (it's
plain Ubuntu 26.04, not Pop!_OS) and wasn't tested.

## Reference numbers (this specific unit)

- CPU: 12th Gen Intel Core i7-1260P (4 P-cores + 8 E-cores, 16 threads)
- EC: ITE IT5570E, 128K flash
- `temp1_crit` (coretemp): 100°C
- Idle, stock curve (fan off): 0 RPM at 63-72°C
- 100% duty (`fan_max` or curve fallback): ~8659-8910 RPM
- This branch's 20% floor, measured: ~1385-1513 RPM
- Estimated audible onset: at or below ~1500-2500 RPM (never precisely
  pinned down — see above)

## Loose ends / things not fully explained

- After `flash_internal`'s forced power-off, the power button needed to be
  pressed twice before the machine would boot, both times. Plausible
  (EC needs to fully re-init before it'll recognize the button; the reset
  is a raw watchdog trigger, not a normal shutdown sequence — see
  `cmd_reset()` in `smfi.c`), but this isn't documented anywhere and wasn't
  independently confirmed against System76's own issue tracker.
- The exact upstream commit that caused the `master`-based RPM bug (see
  above) was never identified.
- Host had `cargo`, `rustc`, `libhidapi-dev`, `pkg-config`, and `sdcc`
  installed solely for this effort. The `sdcc` install is no longer
  needed at all going forward (the build script uses a container instead);
  the other four are still needed on the host to build `tool/` for
  flashing. Remove when done: `sudo apt remove cargo rustc libhidapi-dev pkg-config sdcc && sudo apt autoremove`
  (decline any unrelated old-kernel-package removals it offers).

## References

- Release commit: https://github.com/system76/ec/commit/01be30f107c7930b0673d9f6a35058603f00bd63
- `firmware-open` commit that pinned it: https://github.com/system76/firmware-open/commit/6c402c3e17
- `firmware-open` CHANGELOG: https://github.com/system76/firmware-open/blob/master/CHANGELOG.md
- `firmware-open` `.gitmodules` (shows `ec` vendored as a submodule): https://github.com/system76/firmware-open/blob/master/.gitmodules
- Interpolation algorithm churn on `master` (for context, not exhaustive):
  https://github.com/system76/ec/commit/ae63a9e3 (replaced with stepping),
  https://github.com/system76/ec/commit/9aa8b5a7 (re-added),
  https://github.com/system76/ec/commit/5f36175e (made default again)
