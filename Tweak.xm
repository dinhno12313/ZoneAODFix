#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>
#import <dispatch/dispatch.h>
#import <stdarg.h>
#import <stdlib.h>
#import <unistd.h>

static NSString *const ZAFLogPrefix = @"[ZoneAODFix]";
static NSString *const ZAFVersion = @"0.1.5";
static NSString *const ZAFSleepState = @"Sleep";

static void ZAFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void ZAFLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSLog(@"%@ %@", ZAFLogPrefix, message);
}

typedef NS_ENUM(NSUInteger, ZAFAODPhase) {
    ZAFAODPhaseIdle = 0,
    ZAFAODPhaseArmed,
    ZAFAODPhaseSleepApplied,
    ZAFAODPhaseWaking,
};

static os_unfair_lock ZAFStateLock = OS_UNFAIR_LOCK_INIT;
static ZAFAODPhase ZAFAODCurrentPhase = ZAFAODPhaseIdle;
static id ZAFCachedEngine = nil;
static id ZAFCachedLockedState = nil;
static id ZAFCachedCanonicalSleepState = nil;
static BOOL ZAFSuppressedWakeRequest = NO;
static BOOL ZAFCapturingCanonicalSleepState = NO;
static NSUInteger ZAFSuppressedProgressCount = 0;

static NSString *ZAFPhaseName(ZAFAODPhase phase) {
    switch (phase) {
        case ZAFAODPhaseIdle:
            return @"Idle";
        case ZAFAODPhaseArmed:
            return @"Armed";
        case ZAFAODPhaseSleepApplied:
            return @"SleepApplied";
        case ZAFAODPhaseWaking:
            return @"Waking";
    }

    return @"Unknown";
}

static BOOL ZAFStateIsNamed(id state, NSString *expectedName) {
    if (state == nil) {
        return NO;
    }

    if ([state isKindOfClass:[NSString class]]) {
        return [(NSString *)state isEqualToString:expectedName];
    }

    return [[state description] isEqualToString:expectedName];
}

static id ZAFInvokeOnSleepAndCaptureCanonicalState(id engine, NSString *source) {
    SEL onSleepSelector = sel_registerName("onSleep");
    if (engine == nil || ![engine respondsToSelector:onSleepSelector]) {
        ZAFLog(@"CAPTURE_SLEEP failed source=%@ reason=onSleepUnavailable", source);
        return nil;
    }

    os_unfair_lock_lock(&ZAFStateLock);
    ZAFCapturingCanonicalSleepState = YES;
    os_unfair_lock_unlock(&ZAFStateLock);

    ZAFLog(@"CAPTURE_SLEEP call onSleep source=%@ engine=%p",
           source, (__bridge void *)engine);
    ((void (*)(id, SEL))objc_msgSend)(engine, onSleepSelector);

    os_unfair_lock_lock(&ZAFStateLock);
    id capturedState = ZAFCachedCanonicalSleepState;
    ZAFCapturingCanonicalSleepState = NO;
    os_unfair_lock_unlock(&ZAFStateLock);

    ZAFLog(@"CAPTURE_SLEEP result source=%@ captured=%d state=%@ statePtr=%p",
           source, capturedState != nil, capturedState,
           (__bridge void *)capturedState);
    return capturedState;
}

static void ZAFSendTransition(id engine, id state, BOOL animated) {
    SEL selector = sel_registerName("transitionToState:animated:");
    if (engine == nil || state == nil || ![engine respondsToSelector:selector]) {
        ZAFLog(@"WAKE_REPLAY skipped: engine/state/selector unavailable");
        return;
    }

    ZAFLog(@"WAKE_REPLAY transition state=%@ animated=%d engine=%p",
           state, animated, (__bridge void *)engine);
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(engine, selector, state, animated);
}

static void ZAFReplaySuppressedWakeIfNeeded(NSString *source,
                                             BOOL leaveWakingUntilCurveDisables) {
    __block id engine = nil;
    __block id state = nil;
    BOOL shouldReplay = NO;
    NSUInteger suppressedProgressCount = 0;
    ZAFAODPhase oldPhase;
    ZAFAODPhase newPhase;

    os_unfair_lock_lock(&ZAFStateLock);
    oldPhase = ZAFAODCurrentPhase;
    suppressedProgressCount = ZAFSuppressedProgressCount;

    if (ZAFAODCurrentPhase == ZAFAODPhaseSleepApplied &&
        (ZAFSuppressedWakeRequest || leaveWakingUntilCurveDisables)) {
        engine = ZAFCachedEngine;
        state = ZAFCachedLockedState;
        shouldReplay = engine != nil && state != nil;
    }

    if (leaveWakingUntilCurveDisables &&
        ZAFAODCurrentPhase == ZAFAODPhaseSleepApplied) {
        ZAFAODCurrentPhase = ZAFAODPhaseWaking;
    } else if (!leaveWakingUntilCurveDisables) {
        ZAFAODCurrentPhase = ZAFAODPhaseIdle;
        ZAFSuppressedProgressCount = 0;
    }

    ZAFSuppressedWakeRequest = NO;
    ZAFCachedLockedState = nil;
    newPhase = ZAFAODCurrentPhase;
    os_unfair_lock_unlock(&ZAFStateLock);

    ZAFLog(@"WAKE_SIGNAL source=%@ phase=%@->%@ replay=%d suppressedProgress=%lu",
           source, ZAFPhaseName(oldPhase), ZAFPhaseName(newPhase), shouldReplay,
           (unsigned long)suppressedProgressCount);

    if (shouldReplay) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ZAFSendTransition(engine, state, YES);
        });
    }
}

static void ZAFHandleBrightnessCurve(BOOL enabled, double duration, NSString *source) {
    if (enabled) {
        ZAFAODPhase oldPhase;
        ZAFAODPhase newPhase;

        os_unfair_lock_lock(&ZAFStateLock);
        oldPhase = ZAFAODCurrentPhase;
        if (ZAFAODCurrentPhase == ZAFAODPhaseIdle) {
            ZAFAODCurrentPhase = ZAFAODPhaseArmed;
            ZAFCachedLockedState = nil;
            ZAFSuppressedWakeRequest = NO;
            ZAFSuppressedProgressCount = 0;
        }
        newPhase = ZAFAODCurrentPhase;
        os_unfair_lock_unlock(&ZAFStateLock);

        ZAFLog(@"AOD_CURVE source=%@ enabled=1 duration=%.6f phase=%@->%@",
               source, duration, ZAFPhaseName(oldPhase), ZAFPhaseName(newPhase));
        return;
    }

    ZAFLog(@"AOD_CURVE source=%@ enabled=0 duration=%.6f", source, duration);
    ZAFReplaySuppressedWakeIfNeeded(@"brightnessCurveDisabled", NO);
}

typedef void (*ZAFTransitionIMP)(id, SEL, id, BOOL);
typedef void (*ZAFBooleanDoubleIMP)(id, SEL, BOOL, double);
typedef void (*ZAFTelemetryDisplayUpdateIMP)(id, SEL, id, long long, id);
typedef id (*ZAFResolverIMP)(id, SEL, id, BOOL);
typedef void (*ZAFObjectArgumentIMP)(id, SEL, id);

static id ZAFObjectForSelector(id object, const char *selectorName) {
    SEL selector = sel_registerName(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *ZAFParserRole(id parser) {
    id engine = nil;

    os_unfair_lock_lock(&ZAFStateLock);
    engine = ZAFCachedEngine;
    os_unfair_lock_unlock(&ZAFStateLock);

    if (engine == nil) {
        return @"Unknown";
    }

    if (parser == ZAFObjectForSelector(engine, "bgParser")) {
        return @"Background";
    }
    if (parser == ZAFObjectForSelector(engine, "floatParser")) {
        return @"Floating";
    }
    if (parser == ZAFObjectForSelector(engine, "fgParser")) {
        return @"Foreground";
    }

    return @"Unknown";
}

static void ZAFLogEngineState(id engine, NSString *source) {
    id currentState = ZAFObjectForSelector(engine, "currentState");
    id manualTarget = ZAFObjectForSelector(engine, "manualTargetState");
    BOOL isAnimating = NO;
    SEL isAnimatingSelector = sel_registerName("isAnimatingState");
    if (engine != nil && [engine respondsToSelector:isAnimatingSelector]) {
        isAnimating = ((BOOL (*)(id, SEL))objc_msgSend)(
            engine, isAnimatingSelector
        );
    }

    ZAFLog(@"ENGINE_STATE source=%@ current=%@ currentPtr=%p manualTarget=%@ isAnimating=%d",
           source, currentState, (__bridge void *)currentState,
           manualTarget, isAnimating);
}

static ZAFTransitionIMP ZAFOriginalTransition = NULL;

static void ZAFHookedTransition(id self, SEL _cmd, id state, BOOL animated) {
    BOOL isLocked = ZAFStateIsNamed(state, @"Locked");
    BOOL isSleep = ZAFStateIsNamed(state, ZAFSleepState);
    BOOL captureOnly = NO;
    BOOL replaceWithCanonicalSleep = NO;
    BOOL mustCaptureCanonicalSleep = NO;
    BOOL suppressTransition = NO;
    BOOL markedWakeRequest = NO;
    id canonicalSleepState = nil;
    ZAFAODPhase phaseAtEntry;

    os_unfair_lock_lock(&ZAFStateLock);
    ZAFCachedEngine = self;
    phaseAtEntry = ZAFAODCurrentPhase;

    if (isSleep) {
        ZAFCachedCanonicalSleepState = state;
        canonicalSleepState = state;
        captureOnly = ZAFCapturingCanonicalSleepState;
    }

    if (!captureOnly && ZAFAODCurrentPhase == ZAFAODPhaseArmed && isLocked) {
        ZAFAODCurrentPhase = ZAFAODPhaseSleepApplied;
        ZAFCachedLockedState = state;
        ZAFSuppressedWakeRequest = NO;
        canonicalSleepState = ZAFCachedCanonicalSleepState;
        replaceWithCanonicalSleep = canonicalSleepState != nil;
        mustCaptureCanonicalSleep = canonicalSleepState == nil;
    } else if (!captureOnly &&
               ZAFAODCurrentPhase == ZAFAODPhaseSleepApplied &&
               isLocked) {
        ZAFCachedLockedState = state;
        if (animated) {
            ZAFSuppressedWakeRequest = YES;
            markedWakeRequest = YES;
        }
        suppressTransition = YES;
    }

    ZAFAODPhase phaseAfterDecision = ZAFAODCurrentPhase;
    os_unfair_lock_unlock(&ZAFStateLock);

    if (captureOnly) {
        ZAFLog(@"CAPTURE_SLEEP intercept transition state=%@ statePtr=%p animated=%d",
               state, (__bridge void *)state, animated);
        return;
    }

    if (mustCaptureCanonicalSleep) {
        canonicalSleepState = ZAFInvokeOnSleepAndCaptureCanonicalState(
            self, @"FirstLockedTransition"
        );
        replaceWithCanonicalSleep = canonicalSleepState != nil;
    }

    if (replaceWithCanonicalSleep) {
        ZAFLog(@"REPLACE_ANIMATED Zone transition state=%@ statePtr=%p requestedAnimated=%d with=canonicalSleep sleepPtr=%p appliedAnimated=%d phase=%@->%@",
               state, (__bridge void *)state, animated,
               (__bridge void *)canonicalSleepState, animated,
               ZAFPhaseName(phaseAtEntry),
               ZAFPhaseName(phaseAfterDecision));
        ZAFOriginalTransition(self, _cmd, canonicalSleepState, animated);
        ZAFLogEngineState(self, @"afterAnimatedSleepStart");
        return;
    }

    if (mustCaptureCanonicalSleep) {
        ZAFLog(@"SUPPRESS Zone transition state=%@ animated=%d reason=canonicalSleepUnavailable",
               state, animated);
        return;
    }

    if (suppressTransition) {
        ZAFLog(@"SUPPRESS Zone transition state=%@ animated=%d phase=%@ wakeRequest=%d",
               state, animated, ZAFPhaseName(phaseAtEntry),
               markedWakeRequest);
        return;
    }

    if (isSleep) {
        ZAFLog(@"PASS Zone transition state=Sleep statePtr=%p animated=%d phase=%@",
               (__bridge void *)state, animated, ZAFPhaseName(phaseAtEntry));
    }
    ZAFOriginalTransition(self, _cmd, state, animated);
}

static ZAFTransitionIMP ZAFOriginalManualTransition = NULL;

static void ZAFHookedManualTransition(id self,
                                      SEL _cmd,
                                      id state,
                                      BOOL isDark) {
    BOOL isLocked = ZAFStateIsNamed(state, @"Locked");
    BOOL isSleep = ZAFStateIsNamed(state, ZAFSleepState);
    BOOL captureOnly = NO;
    BOOL replaceWithCanonicalSleep = NO;
    BOOL mustCaptureCanonicalSleep = NO;
    BOOL suppressTransition = NO;
    id canonicalSleepState = nil;
    ZAFAODPhase phaseAtEntry;
    ZAFAODPhase phaseAfterDecision;

    os_unfair_lock_lock(&ZAFStateLock);
    ZAFCachedEngine = self;
    phaseAtEntry = ZAFAODCurrentPhase;

    if (isSleep) {
        ZAFCachedCanonicalSleepState = state;
        canonicalSleepState = state;
        captureOnly = ZAFCapturingCanonicalSleepState;
    }

    if (!captureOnly && ZAFAODCurrentPhase == ZAFAODPhaseArmed && isLocked) {
        ZAFAODCurrentPhase = ZAFAODPhaseSleepApplied;
        ZAFCachedLockedState = state;
        ZAFSuppressedWakeRequest = NO;
        canonicalSleepState = ZAFCachedCanonicalSleepState;
        replaceWithCanonicalSleep = canonicalSleepState != nil;
        mustCaptureCanonicalSleep = canonicalSleepState == nil;
    } else if (!captureOnly &&
               ZAFAODCurrentPhase == ZAFAODPhaseSleepApplied &&
               isLocked) {
        ZAFCachedLockedState = state;
        suppressTransition = YES;
    }

    phaseAfterDecision = ZAFAODCurrentPhase;
    os_unfair_lock_unlock(&ZAFStateLock);

    if (captureOnly) {
        ZAFLog(@"CAPTURE_SLEEP intercept manual state=%@ statePtr=%p isDark=%d",
               state, (__bridge void *)state, isDark);
        return;
    }

    if (mustCaptureCanonicalSleep) {
        canonicalSleepState = ZAFInvokeOnSleepAndCaptureCanonicalState(
            self, @"FirstLockedManualTransition"
        );
        replaceWithCanonicalSleep = canonicalSleepState != nil;
    }

    if (replaceWithCanonicalSleep) {
        ZAFLog(@"REPLACE_ANIMATED Zone manual transition state=%@ statePtr=%p isDark=%d with=canonicalSleep sleepPtr=%p phase=%@->%@",
               state, (__bridge void *)state, isDark,
               (__bridge void *)canonicalSleepState,
               ZAFPhaseName(phaseAtEntry),
               ZAFPhaseName(phaseAfterDecision));
        ZAFOriginalManualTransition(self, _cmd, canonicalSleepState, isDark);
        ZAFLogEngineState(self, @"afterAnimatedSleepFromManual");
        return;
    }

    if (mustCaptureCanonicalSleep) {
        ZAFLog(@"SUPPRESS Zone manual transition state=%@ isDark=%d reason=canonicalSleepUnavailable",
               state, isDark);
        return;
    }

    if (suppressTransition) {
        ZAFLog(@"SUPPRESS Zone manual transition state=%@ isDark=%d phase=%@",
               state, isDark, ZAFPhaseName(phaseAtEntry));
        return;
    }

    if (isSleep) {
        ZAFLog(@"PASS Zone manual transition state=Sleep statePtr=%p isDark=%d phase=%@",
               (__bridge void *)state, isDark, ZAFPhaseName(phaseAtEntry));
    }
    ZAFOriginalManualTransition(self, _cmd, state, isDark);
}

static ZAFBooleanDoubleIMP ZAFOriginalPlatformBrightnessCurve = NULL;
static void ZAFHookedPlatformBrightnessCurve(id self,
                                              SEL _cmd,
                                              BOOL enabled,
                                              double duration) {
    ZAFOriginalPlatformBrightnessCurve(self, _cmd, enabled, duration);
    ZAFHandleBrightnessCurve(enabled, duration, @"SBBacklightPlatformProvider");
}

static ZAFBooleanDoubleIMP ZAFOriginalControllerBrightnessCurve = NULL;
static void ZAFHookedControllerBrightnessCurve(id self,
                                                SEL _cmd,
                                                BOOL enabled,
                                                double duration) {
    ZAFOriginalControllerBrightnessCurve(self, _cmd, enabled, duration);
    ZAFHandleBrightnessCurve(
        enabled, duration, @"SBAlwaysOnBrightnessCurveController"
    );
}

static ZAFTelemetryDisplayUpdateIMP ZAFOriginalWillUpdateDisplay = NULL;
static void ZAFHookedWillUpdateDisplay(id self,
                                       SEL _cmd,
                                       id source,
                                       long long state,
                                       id event) {
    ZAFOriginalWillUpdateDisplay(self, _cmd, source, state, event);

    // On iOS 16.1 / iPhone 14 Pro, raw state 2 is ActiveOn. The captured
    // transition is InactiveOn -> ActiveOn for AOD wake and Off -> ActiveOn
    // for ordinary wake. The phase guard makes ordinary wake a no-op here.
    if (state == 2) {
        ZAFReplaySuppressedWakeIfNeeded(@"backlightWillUpdateActiveOn", YES);
    }
}

static ZAFResolverIMP ZAFOriginalResolver = NULL;
static id ZAFHookedResolver(id self, SEL _cmd, id requestedState, BOOL isDark) {
    id resolvedState = ZAFOriginalResolver(
        self, _cmd, requestedState, isDark
    );

    ZAFAODPhase phase;
    os_unfair_lock_lock(&ZAFStateLock);
    phase = ZAFAODCurrentPhase;
    os_unfair_lock_unlock(&ZAFStateLock);

    if (ZAFStateIsNamed(requestedState, ZAFSleepState)) {
        id availableStates = ZAFObjectForSelector(self, "availableStates");
        BOOL hasExactState = NO;
        if ([availableStates respondsToSelector:@selector(containsObject:)]) {
            hasExactState = [availableStates containsObject:requestedState];
        }

        ZAFLog(@"RESOLVE parser=%@ parserPtr=%p requested=%@ requestedPtr=%p isDark=%d resolved=%@ resolvedPtr=%p exactAvailable=%d available=%@ phase=%@",
               ZAFParserRole(self), (__bridge void *)self,
               requestedState, (__bridge void *)requestedState, isDark,
               resolvedState, (__bridge void *)resolvedState,
               hasExactState, availableStates, ZAFPhaseName(phase));
    }

    return resolvedState;
}

static ZAFObjectArgumentIMP ZAFOriginalOnProgress = NULL;
static void ZAFHookedOnProgress(id self, SEL _cmd, id notification) {
    BOOL suppress = NO;
    NSUInteger suppressedCount = 0;

    os_unfair_lock_lock(&ZAFStateLock);
    if (ZAFAODCurrentPhase == ZAFAODPhaseSleepApplied) {
        suppress = YES;
        ZAFSuppressedProgressCount++;
        suppressedCount = ZAFSuppressedProgressCount;
    }
    os_unfair_lock_unlock(&ZAFStateLock);

    if (suppress) {
        if (suppressedCount == 1) {
            id userInfo = ZAFObjectForSelector(notification, "userInfo");
            id progress = nil;
            if ([userInfo respondsToSelector:@selector(objectForKey:)]) {
                progress = [userInfo objectForKey:@"progress"];
            }

            ZAFLog(@"SUPPRESS_PROGRESS first value=%@ source=%@ phase=SleepApplied",
                   progress, notification);
        }
        return;
    }

    ZAFOriginalOnProgress(self, _cmd, notification);
}

static BOOL ZAFTypeIsVoid(const char *type) {
    return type != NULL && type[0] == 'v';
}

static BOOL ZAFTypeIsObject(const char *type) {
    return type != NULL && type[0] == '@';
}

static BOOL ZAFTypeIsBoolean(const char *type) {
    return type != NULL && (type[0] == 'B' || type[0] == 'c');
}

static BOOL ZAFMethodIsVoidNoArguments(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 2) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    BOOL compatible = ZAFTypeIsVoid(returnType);
    free(returnType);
    return compatible;
}

static BOOL ZAFMethodIsTransition(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 4) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *stateType = method_copyArgumentType(method, 2);
    char *animatedType = method_copyArgumentType(method, 3);
    BOOL compatible = ZAFTypeIsVoid(returnType) &&
                      ZAFTypeIsObject(stateType) &&
                      ZAFTypeIsBoolean(animatedType);
    free(returnType);
    free(stateType);
    free(animatedType);
    return compatible;
}

static BOOL ZAFMethodIsResolver(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 4) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *stateType = method_copyArgumentType(method, 2);
    char *darkType = method_copyArgumentType(method, 3);
    BOOL compatible = ZAFTypeIsObject(returnType) &&
                      ZAFTypeIsObject(stateType) &&
                      ZAFTypeIsBoolean(darkType);
    free(returnType);
    free(stateType);
    free(darkType);
    return compatible;
}

static BOOL ZAFMethodIsVoidObjectArgument(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *argumentType = method_copyArgumentType(method, 2);
    BOOL compatible = ZAFTypeIsVoid(returnType) &&
                      ZAFTypeIsObject(argumentType);
    free(returnType);
    free(argumentType);
    return compatible;
}

static BOOL ZAFMethodIsBooleanDouble(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 4) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *enabledType = method_copyArgumentType(method, 2);
    char *durationType = method_copyArgumentType(method, 3);
    BOOL compatible = ZAFTypeIsVoid(returnType) &&
                      ZAFTypeIsBoolean(enabledType) &&
                      durationType != NULL && durationType[0] == 'd';
    free(returnType);
    free(enabledType);
    free(durationType);
    return compatible;
}

static BOOL ZAFMethodIsTelemetryDisplayUpdate(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 5) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *sourceType = method_copyArgumentType(method, 2);
    char *stateType = method_copyArgumentType(method, 3);
    char *eventType = method_copyArgumentType(method, 4);
    BOOL compatible = ZAFTypeIsVoid(returnType) &&
                      ZAFTypeIsObject(sourceType) &&
                      stateType != NULL &&
                      (stateType[0] == 'q' || stateType[0] == 'Q') &&
                      ZAFTypeIsObject(eventType);
    free(returnType);
    free(sourceType);
    free(stateType);
    free(eventType);
    return compatible;
}

typedef BOOL (*ZAFSignatureValidator)(Method);

static BOOL ZAFInstallHook(const char *className,
                           const char *selectorName,
                           IMP replacement,
                           IMP *original,
                           ZAFSignatureValidator validator,
                           BOOL reportUnavailable) {
    Class targetClass = objc_getClass(className);
    if (targetClass == Nil) {
        if (reportUnavailable) {
            ZAFLog(@"UNAVAILABLE class=%s selector=%s", className, selectorName);
        }
        return NO;
    }

    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(targetClass, selector);
    if (method == NULL) {
        if (reportUnavailable) {
            ZAFLog(@"UNAVAILABLE %@ -%@",
                   NSStringFromClass(targetClass), NSStringFromSelector(selector));
        }
        return NO;
    }

    if (!validator(method)) {
        if (reportUnavailable) {
            ZAFLog(@"SKIP %@ -%@: unexpected type=%s",
                   NSStringFromClass(targetClass), NSStringFromSelector(selector),
                   method_getTypeEncoding(method));
        }
        return NO;
    }

    MSHookMessageEx(targetClass, selector, replacement, original);
    ZAFLog(@"HOOKED %@ -%@: type=%s",
           NSStringFromClass(targetClass), NSStringFromSelector(selector),
           method_getTypeEncoding(method));
    return YES;
}

static BOOL ZAFDidHookTransition = NO;
static BOOL ZAFDidHookManualTransition = NO;
static BOOL ZAFDidHookBrightnessSignal = NO;
static BOOL ZAFDidHookWakeTelemetry = NO;
static BOOL ZAFDidHookResolver = NO;
static BOOL ZAFDidHookOnProgress = NO;

static void ZAFInstallAvailableHooks(BOOL reportUnavailable) {
    Class zoneClass = objc_getClass("ZoneRenderEngineEnhanced");
    BOOL onSleepAvailable = NO;

    if (zoneClass != Nil) {
        Method onSleepMethod = class_getInstanceMethod(
            zoneClass, sel_registerName("onSleep")
        );
        onSleepAvailable = ZAFMethodIsVoidNoArguments(onSleepMethod);
        if (!onSleepAvailable && reportUnavailable) {
            ZAFLog(@"UNAVAILABLE compatible ZoneRenderEngineEnhanced -onSleep");
        }
    } else if (reportUnavailable) {
        ZAFLog(@"UNAVAILABLE class ZoneRenderEngineEnhanced");
    }

    if (!ZAFDidHookTransition && zoneClass != Nil && onSleepAvailable) {
        ZAFDidHookTransition = ZAFInstallHook(
            "ZoneRenderEngineEnhanced", "transitionToState:animated:",
            (IMP)ZAFHookedTransition,
            (IMP *)&ZAFOriginalTransition,
            ZAFMethodIsTransition,
            reportUnavailable
        );
    }

    if (!ZAFDidHookManualTransition && zoneClass != Nil && onSleepAvailable) {
        ZAFDidHookManualTransition = ZAFInstallHook(
            "ZoneRenderEngineEnhanced",
            "startManualDisplayLinkTransitionToState:isDark:",
            (IMP)ZAFHookedManualTransition,
            (IMP *)&ZAFOriginalManualTransition,
            ZAFMethodIsTransition,
            reportUnavailable
        );
    }

    if (!ZAFDidHookOnProgress && zoneClass != Nil && onSleepAvailable) {
        ZAFDidHookOnProgress = ZAFInstallHook(
            "ZoneRenderEngineEnhanced", "onProgress:",
            (IMP)ZAFHookedOnProgress,
            (IMP *)&ZAFOriginalOnProgress,
            ZAFMethodIsVoidObjectArgument,
            reportUnavailable
        );
    }

    if (!ZAFDidHookResolver) {
        ZAFDidHookResolver = ZAFInstallHook(
            "ZoneCAMLParserEnhanced",
            "resolveRealStateNameFor:isDark:",
            (IMP)ZAFHookedResolver,
            (IMP *)&ZAFOriginalResolver,
            ZAFMethodIsResolver,
            reportUnavailable
        );
    }

    if (!ZAFDidHookBrightnessSignal) {
        ZAFDidHookBrightnessSignal = ZAFInstallHook(
            "SBBacklightPlatformProvider",
            "useAlwaysOnBrightnessCurve:withRampDuration:",
            (IMP)ZAFHookedPlatformBrightnessCurve,
            (IMP *)&ZAFOriginalPlatformBrightnessCurve,
            ZAFMethodIsBooleanDouble,
            NO
        );

        if (!ZAFDidHookBrightnessSignal) {
            ZAFDidHookBrightnessSignal = ZAFInstallHook(
                "SBAlwaysOnBrightnessCurveController",
                "setUseAlwaysOnBrightnessCurve:withRampDuration:",
                (IMP)ZAFHookedControllerBrightnessCurve,
                (IMP *)&ZAFOriginalControllerBrightnessCurve,
                ZAFMethodIsBooleanDouble,
                reportUnavailable
            );
        }
    }

    if (!ZAFDidHookWakeTelemetry) {
        ZAFDidHookWakeTelemetry = ZAFInstallHook(
            "SBAlwaysOnTelemetryEmitter",
            "backlightTelemetrySource:willUpdateDisplayForState:forEvent:",
            (IMP)ZAFHookedWillUpdateDisplay,
            (IMP *)&ZAFOriginalWillUpdateDisplay,
            ZAFMethodIsTelemetryDisplayUpdate,
            reportUnavailable
        );
    }
}

__attribute__((constructor))
static void ZAFInitialize(void) {
    @autoreleasepool {
        ZAFLog(@"LOADED version=%@ process=%@ pid=%d",
               ZAFVersion, NSProcessInfo.processInfo.processName, getpid());
        ZAFInstallAvailableHooks(YES);

        // Zone or a private SpringBoard framework may load after this dylib.
        const NSTimeInterval retryDelays[] = { 1.0, 3.0, 10.0, 30.0 };
        const NSUInteger retryCount = sizeof(retryDelays) / sizeof(retryDelays[0]);
        for (NSUInteger index = 0; index < retryCount; index++) {
            BOOL reportUnavailable = index == retryCount - 1;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(retryDelays[index] * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    ZAFInstallAvailableHooks(reportUnavailable);
                }
            );
        }
    }
}
