# ZoneAODFix

Version 0.1.5 is a narrowly scoped companion fix for the existing Zone tweak
on iOS 16.1 / iPhone 14 Pro. It targets rootless Dopamine and SpringBoard.

This repository contains only the companion tweak source. It does not include
or redistribute `Zone.dylib`, wallpapers, or other files belonging to Zone.

## Requirements

- A rootless iOS jailbreak with ElleKit/Substrate compatibility
- Zone with `ZoneRenderEngineEnhanced`
- An arm64e device; tested on iPhone 14 Pro with iOS 16.1
- Theos when building from source

The fix uses the runtime sequence established by ZoneAODDebug 0.0.4:

1. `SBBacklightPlatformProvider` enables the Always-On brightness curve.
2. Zone requests `Locked animated=1` instead of entering its Sleep stage.
3. Zone later requests `Locked animated=0`, which keeps Locked visible in AOD.
4. Wake is reported as backlight state `ActiveOn` (`rawState=2`) before the
   display becomes physically active.

The 0.1.4 runtime trace proved that all three Zone parsers resolved and applied
the exact Sleep state. About 122 ms later, `ZoneRenderEngineEnhanced
-onProgress:` began scrubbing the Background and Floating packages between
Locked and Unlock every display frame, overwriting the visible Sleep state
without going through `transitionToState:`. Version 0.1.5 suppresses only that
progress callback while AOD is inactive-on. It restores Zone's animated Sleep
transition and allows progress again as soon as wake begins. Subsequent Locked
writes remain suppressed during AOD, and one Locked transition is replayed on
wake.

For verification, 0.1.5 also logs the result of
`ZoneCAMLParserEnhanced -resolveRealStateNameFor:isDark:` independently for the
Background, Floating, and Foreground packages. It does not alter the resolver,
replace Zone's renderer, or modify files belonging to Zone.

Every diagnostic line begins with `[ZoneAODFix]`.

## Build

```sh
cd ZoneAODFix
export THEOS=/path/to/theos
make clean package FINALPACKAGE=1
```

The rootless package is written to `packages/`.

## Install and first test

Remove ZoneAODDebug before the first behavior test so call-stack logging does
not affect timing:

```sh
dpkg -r com.dinhnguyenx.zoneaoddebug
dpkg -i /var/mobile/com.dinhnguyenx.zoneaodfix_0.1.5_iphoneos-arm64.deb
sbreload
```

Capture the lightweight fix log from the Mac:

```sh
idevicesyslog -m '[ZoneAODFix]' --no-colors \
  | tee "$HOME/Desktop/ZoneAODFix-0.1.5.log"
```

Verify three lock/AOD/wake cycles. Then test one notification while AOD is
visible and one immediate wake shortly after locking.

Expected entry log:

```text
AOD_CURVE ... enabled=1 ... phase=Idle->Armed
CAPTURE_SLEEP call onSleep ...
CAPTURE_SLEEP intercept transition state=Sleep statePtr=...
CAPTURE_SLEEP result ... captured=1 ...
REPLACE_ANIMATED Zone transition state=Locked ... with=canonicalSleep ... appliedAnimated=1
RESOLVE parser=Background ... requested=Sleep ... resolved=... exactAvailable=...
RESOLVE parser=Floating ... requested=Sleep ... resolved=... exactAvailable=...
RESOLVE parser=Foreground ... requested=Sleep ... resolved=... exactAvailable=...
ENGINE_STATE source=afterAnimatedSleepStart current=Sleep ... isAnimating=1
SUPPRESS_PROGRESS first value=... phase=SleepApplied
SUPPRESS Zone transition state=Locked animated=0
```

Expected wake log:

```text
SUPPRESS Zone transition state=Locked animated=1 ... wakeRequest=1
WAKE_SIGNAL ... replay=1 suppressedProgress=...
WAKE_REPLAY transition state=Locked animated=1
AOD_CURVE ... enabled=0 ...
```

## Roll back

If SpringBoard behavior is incorrect, remove only this companion package and
restart SpringBoard:

```sh
dpkg -r com.dinhnguyenx.zoneaodfix
sbreload
```

Zone itself is not modified, so removing ZoneAODFix restores the original
behavior.
