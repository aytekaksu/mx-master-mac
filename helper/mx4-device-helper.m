// MX Master 4 event bridge. Default mode is a listen-only, read-only diagnostic.
// Build and test from the repository root with: make && make test
// Run a permission check with: build/mx4-device-helper --dry-run
// Active mode: Hammerspoon must launch this directly with
// --active --parent-pid <its PID>. It exits if Hammerspoon exits, and requires
// Accessibility/Input Monitoring access. Its streaming stdin must receive a
// heartbeat byte about every 0.5 s; EOF or 3 s without a byte exits the helper.

#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDDeviceKeys.h>
#import <CoreFoundation/CoreFoundation.h>
#include <libproc.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <poll.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

// The same non-public HID association used by LinearMouse. If either function
// or the IORegistry identity is unavailable, pointer events pass unchanged.
typedef CFTypeRef IOHIDEventRef;
extern IOHIDEventRef CGEventCopyIOHIDEvent(CGEventRef event);
extern uint64_t IOHIDEventGetSenderID(IOHIDEventRef event);

enum {
    kMXVendorID = 1133,
    kMXProductID = 45122,
    kThumbKeyCode = 105, // F13 from Logi Options+
    kThirdKeyCode = 107, // F14 from Logi Options+
    kMarkerKeyCode = 113, // F15 received by Hammerspoon
    kMarkerBase = 0x4D5800,
    kSenderCacheSize = 64,
    kThumbWheelIntervalNs = 55000000,
    kThirdWheelIntervalNs = 110000000,
    kReceiverHeartbeatPollMs = 250
};

static const uint64_t kReceiverHeartbeatTimeoutNs = 3000000000ULL;
static bool activeDiagnosticsNonblocking = false;
static _Atomic bool activeExitReported = false;

typedef enum {
    kExitLoopUnknown = 0,
    kExitTapDisabledByTimeout,
    kExitTapDisabledByUserInput
} EventLoopExitReason;

static const char *eventLoopExitReasonName(EventLoopExitReason reason) {
    switch (reason) {
    case kExitTapDisabledByTimeout: return "event_tap_disabled_by_timeout";
    case kExitTapDisabledByUserInput: return "event_tap_disabled_by_user_input";
    default: return "event_loop_stopped";
    }
}

// One short diagnostic at process exit; never used for ordinary input events.
// The fd is explicitly nonblocking, so a stalled Hammerspoon stream callback
// cannot keep a failed helper alive while its event tap is still installed.
static void reportActiveExit(const char *reason) {
    if (!activeDiagnosticsNonblocking) return;
    if (atomic_exchange_explicit(&activeExitReported, true, memory_order_relaxed)) return;
    char line[160];
    int length = snprintf(line, sizeof(line), "MX4 helper exit: %s\n", reason);
    if (length > 0 && (size_t)length < sizeof(line))
        (void)write(STDERR_FILENO, line, (size_t)length);
}

static bool configureActiveDiagnostics(void) {
    int flags = fcntl(STDERR_FILENO, F_GETFL);
    if (flags < 0 || fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK) != 0)
        return false;
    activeDiagnosticsNonblocking = true;
    return true;
}

static const char kLogiAgentPath[] =
    "/Library/Application Support/Logitech.localized/LogiOptionsPlus/"
    "logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent";
static const char kHammerspoonPath[] =
    "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon";

typedef enum {
    kActionThumbWheelUp = 1,
    kActionThumbWheelDown = 2,
    kActionThumbLeftClose = 3,
    kActionThumbRightNew = 4,
    kActionThirdWheelUp = 5,
    kActionThirdWheelDown = 6,
    kActionThirdCopy = 7,
    kActionThirdPaste = 8,
    kActionThirdSelectAll = 9,
    kActionThirdReleaseCommit = 10
} MXAction;

typedef struct {
    uint64_t senderID;
    bool isMX;
    bool occupied;
} SenderCacheEntry;

typedef struct {
    bool consumed;
    uint64_t senderID;
    enum { kOwnerNone, kOwnerThumb, kOwnerThird } owner;
} ConsumedButton;

typedef struct {
    bool active;
    pid_t parentPID;
    _Atomic uint64_t lastHeartbeatTimeNs;
    _Atomic int eventLoopExitReason;
    bool thumbDown;
    bool thirdDown;
    pid_t layerSourcePID;
    bool thirdNavigationPending;
    bool thirdLeftDown;
    bool thirdRightDown;
    bool thirdBothClicked;
    ConsumedButton left;
    ConsumedButton right;
    double wheelRemainder;
    int wheelDirection;
    uint64_t lastWheelActionTimeNs;
    int lastWheelActionDirection;
    SenderCacheEntry cache[kSenderCacheSize];
    size_t cacheNext;
    CFMachPortRef tap;
#ifdef MX4_TESTING
    MXAction emittedActions[32];
    size_t emittedActionCount;
#endif
} Bridge;

static bool trustedHammerspoonParent(pid_t parentPID) {
    if (parentPID <= 1 || getppid() != parentPID) return false;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int length = proc_pidpath(parentPID, path, sizeof(path));
    return length > 0 && strcmp(path, kHammerspoonPath) == 0;
}

static int acquireActiveInstanceLock(void) {
    char tempDirectory[PATH_MAX] = {0};
    size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, tempDirectory,
                            sizeof(tempDirectory));
    if (length == 0 || length >= sizeof(tempDirectory)) return -1;
    char lockPath[PATH_MAX] = {0};
    int written = snprintf(lockPath, sizeof(lockPath), "%smx4-device-helper.lock",
                           tempDirectory);
    if (written < 0 || (size_t)written >= sizeof(lockPath)) return -1;
    int fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    struct stat info = {0};
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return -1;
    }
    return fd; // Keep open for the entire active lifetime.
}

static int registerParentExitWatch(pid_t parentPID) {
    int queue = kqueue();
    if (queue < 0) return -1;
    struct kevent change;
    EV_SET(&change, parentPID, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL) < 0 || getppid() != parentPID) {
        close(queue);
        return -1;
    }
    return queue;
}

static void *watchParentExit(void *context) {
    int queue = *(int *)context;
    struct kevent event;
    for (;;) {
        int count = kevent(queue, NULL, 0, &event, 1, NULL);
        if (count > 0) {
            reportActiveExit("hammerspoon_parent_exited");
            _exit(0); // The OS releases the event tap and instance lock.
        }
        if (count < 0 && errno != EINTR) {
            reportActiveExit("parent_watch_error");
            _exit(0);
        }
    }
}

static bool numberProperty(io_registry_entry_t entry, CFStringRef key, int64_t *out) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return false;
    bool ok = CFGetTypeID(value) == CFNumberGetTypeID() &&
              CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, out);
    CFRelease(value);
    return ok;
}

static bool trustedLogiAgentPID(int64_t pidValue) {
    if (pidValue <= 0 || pidValue > INT_MAX) return false;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int length = proc_pidpath((pid_t)pidValue, path, sizeof(path));
    return length > 0 && strcmp(path, kLogiAgentPath) == 0;
}

static bool pointsWithMouseUsage(io_registry_entry_t service) {
    int64_t page = -1, usage = -1;
    if (numberProperty(service, CFSTR(kIOHIDPrimaryUsagePageKey), &page) &&
        numberProperty(service, CFSTR(kIOHIDPrimaryUsageKey), &usage) &&
        page == 1 && (usage == 1 || usage == 2)) return true;

    CFTypeRef pairs = IORegistryEntryCreateCFProperty(
        service, CFSTR(kIOHIDDeviceUsagePairsKey), kCFAllocatorDefault, 0);
    if (!pairs) return false;
    bool pointing = false;
    if (CFGetTypeID(pairs) == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)pairs;
        for (CFIndex i = 0; i < CFArrayGetCount(array); ++i) {
            CFTypeRef item = CFArrayGetValueAtIndex(array, i);
            if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
            CFDictionaryRef pair = (CFDictionaryRef)item;
            CFTypeRef pageValue = CFDictionaryGetValue(pair, CFSTR("DeviceUsagePage"));
            CFTypeRef usageValue = CFDictionaryGetValue(pair, CFSTR("DeviceUsage"));
            if (!pageValue || !usageValue ||
                CFGetTypeID(pageValue) != CFNumberGetTypeID() ||
                CFGetTypeID(usageValue) != CFNumberGetTypeID()) continue;
            int64_t pairPage = -1, pairUsage = -1;
            CFNumberGetValue((CFNumberRef)pageValue, kCFNumberSInt64Type, &pairPage);
            CFNumberGetValue((CFNumberRef)usageValue, kCFNumberSInt64Type, &pairUsage);
            if (pairPage == 1 && (pairUsage == 1 || pairUsage == 2)) {
                pointing = true;
                break;
            }
        }
    }
    CFRelease(pairs);
    return pointing;
}

typedef struct {
    bool valid;
    unsigned logitechPointingCount;
    bool solePointingDeviceIsMX;
} LogitechPointerInventory;

static LogitechPointerInventory connectedLogitechPointers(void) {
    LogitechPointerInventory result = {0};
    CFMutableDictionaryRef matching = IOServiceMatching("IOHIDDevice");
    if (!matching) return result;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS)
        return result;
    result.valid = true;
    bool singleIsMX = false;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        int64_t vendor = -1, product = -1;
        bool vendorKnown = numberProperty(service, CFSTR(kIOHIDVendorIDKey), &vendor);
        bool productKnown = numberProperty(service, CFSTR(kIOHIDProductIDKey), &product);
        if (vendorKnown && vendor == kMXVendorID && pointsWithMouseUsage(service)) {
            ++result.logitechPointingCount;
            singleIsMX = productKnown && product == kMXProductID;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    result.solePointingDeviceIsMX = result.logitechPointingCount == 1 && singleIsMX;
    return result;
}

typedef enum { kOriginUnverified, kOriginPhysicalMX, kOriginLogiInferredMX } PointerOrigin;

// Pure classifier for unit tests. A nonzero sender never falls back to an
// application PID. Sender-zero clicks also always fail open.
static PointerOrigin classifyPointerOrigin(CGEventType type, uint64_t senderID,
                                           bool senderVerifiedMX,
                                           bool sourceIsTrustedLogiAgent,
                                           LogitechPointerInventory inventory) {
    if (senderID != 0) return senderVerifiedMX ? kOriginPhysicalMX : kOriginUnverified;
    if (type == kCGEventScrollWheel && sourceIsTrustedLogiAgent && inventory.valid &&
        inventory.logitechPointingCount == 1 && inventory.solePointingDeviceIsMX)
        return kOriginLogiInferredMX;
    return kOriginUnverified;
}

typedef enum { kSenderUnknown, kSenderKnownMX, kSenderKnownOther } SenderIdentity;

static SenderIdentity matchingMXAncestor(io_registry_entry_t service) {
    io_registry_entry_t current = service; // Takes ownership of service.
    for (unsigned depth = 0; current && depth < 16; ++depth) {
        int64_t vendor = -1, product = -1;
        bool hasVendor = numberProperty(current, CFSTR(kIOHIDVendorIDKey), &vendor);
        bool hasProduct = numberProperty(current, CFSTR(kIOHIDProductIDKey), &product);
        if (hasVendor && hasProduct) {
            if (vendor == kMXVendorID && product == kMXProductID) {
                IOObjectRelease(current);
                return kSenderKnownMX;
            }
            // A distinct HID identity on this ancestor rules out the MX.
            IOObjectRelease(current);
            return kSenderKnownOther;
        }
        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        current = status == KERN_SUCCESS ? parent : IO_OBJECT_NULL;
    }
    if (current) IOObjectRelease(current);
    return kSenderUnknown;
}

static bool cachedNonMXSender(const Bridge *bridge, uint64_t senderID) {
    if (senderID == 0) return false;
    for (size_t i = 0; i < kSenderCacheSize; ++i) {
        const SenderCacheEntry *entry = &bridge->cache[i];
        if (entry->occupied && entry->senderID == senderID && !entry->isMX)
            return true;
    }
    return false;
}

static bool verifiedMXSender(Bridge *bridge, uint64_t senderID) {
    if (!senderID) return false;
    // IORegistry entry IDs are unique until reboot. A classified trackpad or
    // other non-MX sender cannot become this MX while this process is alive.
    // Avoid a registry query for every high-rate trackpad scroll event.
    if (cachedNonMXSender(bridge, senderID)) return false;

    // Recheck that the service still exists on every event. Registry IDs are
    // unique until reboot; a reconnected mouse receives a new ID and is
    // classified again. A stale positive cache entry cannot authorize input.
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(senderID);
    if (!matching) return false;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) return false;
    uint64_t actualID = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &actualID) != KERN_SUCCESS ||
        actualID != senderID) {
        IOObjectRelease(service);
        return false;
    }

    for (size_t i = 0; i < kSenderCacheSize; ++i) {
        SenderCacheEntry *entry = &bridge->cache[i];
        if (entry->occupied && entry->senderID == senderID) {
            IOObjectRelease(service);
            return entry->isMX;
        }
    }

    SenderIdentity identity = matchingMXAncestor(service); // Releases service.
    if (identity == kSenderUnknown) return false; // Retry when HID metadata appears.
    bool isMX = identity == kSenderKnownMX;
    SenderCacheEntry *entry = &bridge->cache[bridge->cacheNext++ % kSenderCacheSize];
    *entry = (SenderCacheEntry){ .senderID = senderID, .isMX = isMX, .occupied = true };
    if (!bridge->active) {
        fprintf(stderr, "sender=%llu classified=%s\n",
                (unsigned long long)senderID, isMX ? "MX Master 4" : "other");
    }
    return isMX;
}

static uint64_t eventSenderID(CGEventRef event) {
    IOHIDEventRef hid = CGEventCopyIOHIDEvent(event);
    if (!hid) return 0;
    uint64_t senderID = IOHIDEventGetSenderID(hid);
    CFRelease(hid);
    return senderID;
}

static void resetLayerState(Bridge *bridge) {
    bridge->thumbDown = false;
    bridge->thirdDown = false;
    bridge->layerSourcePID = 0;
    bridge->thirdNavigationPending = false;
    bridge->thirdLeftDown = false;
    bridge->thirdRightDown = false;
    bridge->thirdBothClicked = false;
    bridge->wheelRemainder = 0;
    bridge->wheelDirection = 0;
    bridge->lastWheelActionTimeNs = 0;
    bridge->lastWheelActionDirection = 0;
    // Keep consumed down records until their matching physical up arrives.
}

static void resetAllState(Bridge *bridge) {
    resetLayerState(bridge);
    bridge->left = (ConsumedButton){0};
    bridge->right = (ConsumedButton){0};
}

static void resetWheelProgress(Bridge *bridge) {
    bridge->wheelRemainder = 0;
    bridge->wheelDirection = 0;
    bridge->lastWheelActionTimeNs = 0;
    bridge->lastWheelActionDirection = 0;
}

static void emitMarker(Bridge *bridge, MXAction action) {
#ifdef MX4_TESTING
    if (bridge->emittedActionCount < 32)
        bridge->emittedActions[bridge->emittedActionCount++] = action;
#endif
    if (!bridge->active) {
        fprintf(stdout, "would-emit action=%d\n", action);
        fflush(stdout);
        return;
    }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!source) return;
    for (int down = 1; down >= 0; --down) {
        CGEventRef marker = CGEventCreateKeyboardEvent(source, kMarkerKeyCode, down != 0);
        if (!marker) continue;
        CGEventSetIntegerValueField(marker, kCGEventSourceUserData, kMarkerBase + action);
        CGEventPost(kCGSessionEventTap, marker);
        CFRelease(marker);
    }
    CFRelease(source);
}

static bool handleClick(Bridge *bridge, CGEventType type, uint64_t senderID) {
    bool left = type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp;
    bool down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown;
    ConsumedButton *button = left ? &bridge->left : &bridge->right;

    if (!down) {
        if (!button->consumed || button->senderID != senderID) return false;
        int owner = button->owner;
        *button = (ConsumedButton){0};
        if (owner == kOwnerThird) {
            if (left) bridge->thirdLeftDown = false;
            else bridge->thirdRightDown = false;
            if (bridge->thirdDown && !bridge->thirdBothClicked &&
                !bridge->thirdLeftDown && !bridge->thirdRightDown) {
                emitMarker(bridge, left ? kActionThirdCopy : kActionThirdPaste);
            }
            if (!bridge->thirdLeftDown && !bridge->thirdRightDown)
                bridge->thirdBothClicked = false;
        }
        return true;
    }

    // A repeated down from the same sender must stay suppressed; a down from
    // another device passes unchanged and cannot steal its stored release.
    if (button->consumed) return button->senderID == senderID;
    int owner = bridge->thumbDown ? kOwnerThumb :
                bridge->thirdDown ? kOwnerThird : kOwnerNone;
    if (owner == kOwnerNone) return false;

    *button = (ConsumedButton){ .consumed = true, .senderID = senderID, .owner = owner };
    if (owner == kOwnerThumb) {
        emitMarker(bridge, left ? kActionThumbLeftClose : kActionThumbRightNew);
    } else {
        if (left) bridge->thirdLeftDown = true;
        else bridge->thirdRightDown = true;
        if (bridge->thirdLeftDown && bridge->thirdRightDown && !bridge->thirdBothClicked) {
            bridge->thirdBothClicked = true;
            emitMarker(bridge, kActionThirdSelectAll);
        }
    }
    return true;
}

static bool handleDrag(Bridge *bridge, CGEventType type, uint64_t senderID) {
    ConsumedButton *button = type == kCGEventLeftMouseDragged ? &bridge->left : &bridge->right;
    return button->consumed && button->senderID == senderID;
}

static double verticalWheelDelta(CGEventRef event) {
    double delta = (double)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    if (delta != 0) return delta;
    // Fixed-point wheel delta keeps the fractional impulses of smooth wheels.
    delta = (double)CGEventGetIntegerValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1) / 65536.0;
    if (delta != 0) return delta;
    return (double)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
}

static uint64_t monotonicTimeNs(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static bool receiverHeartbeatExpired(uint64_t lastBeatNs, uint64_t nowNs) {
    return lastBeatNs == 0 || nowNs == 0 || nowNs < lastBeatNs ||
           nowNs - lastBeatNs >= kReceiverHeartbeatTimeoutNs;
}

static bool receiverHeartbeatHealthy(Bridge *bridge) {
    uint64_t lastBeatNs = atomic_load_explicit(&bridge->lastHeartbeatTimeNs,
                                                memory_order_relaxed);
    return !receiverHeartbeatExpired(lastBeatNs, monotonicTimeNs());
}

static void *watchReceiverHeartbeat(void *context) {
    Bridge *bridge = context;
    struct pollfd input = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP };
    for (;;) {
        int ready = poll(&input, 1, kReceiverHeartbeatPollMs);
        if (!receiverHeartbeatHealthy(bridge)) {
            reportActiveExit("receiver_heartbeat_timeout");
            _exit(0);
        }
        if (ready < 0) {
            if (errno == EINTR) continue;
            reportActiveExit("receiver_heartbeat_poll_error");
            _exit(0);
        }
        if (ready == 0) continue;
        if (input.revents & (POLLERR | POLLNVAL)) {
            reportActiveExit("receiver_heartbeat_stdin_error");
            _exit(0);
        }
        if (input.revents & (POLLIN | POLLHUP)) {
            char beat[256];
            ssize_t count = read(STDIN_FILENO, beat, sizeof(beat));
            if (count > 0) {
                atomic_store_explicit(&bridge->lastHeartbeatTimeNs,
                                      monotonicTimeNs(), memory_order_relaxed);
            } else if (count == 0) {
                reportActiveExit("receiver_heartbeat_stdin_eof");
                _exit(0);
            } else if (errno != EINTR && errno != EAGAIN) {
                reportActiveExit("receiver_heartbeat_read_error");
                _exit(0);
            }
        }
    }
}

// Coalesce a burst of wheel events in the same direction. A reversal is
// always emitted immediately, even when it occurs within the time interval.
static bool shouldEmitWheelAction(Bridge *bridge, int direction, uint64_t nowNs) {
    uint64_t interval = bridge->thumbDown ? kThumbWheelIntervalNs : kThirdWheelIntervalNs;
    if (bridge->lastWheelActionDirection == direction &&
        (nowNs < bridge->lastWheelActionTimeNs ||
         nowNs - bridge->lastWheelActionTimeNs < interval)) return false;
    bridge->lastWheelActionDirection = direction;
    bridge->lastWheelActionTimeNs = nowNs;
    return true;
}

static bool handleWheelDelta(Bridge *bridge, double vertical, double horizontal,
                             bool momentum, uint64_t nowNs) {
    if (!bridge->thumbDown && !bridge->thirdDown) return false;
    if (vertical == 0) return false; // Preserve horizontal-only scrolling.
    if (horizontal != 0 && __builtin_fabs(horizontal) > __builtin_fabs(vertical))
        return false;

    if (momentum)
        return true; // Do not turn momentum into repeated tab/window actions.

    int direction = vertical > 0 ? 1 : -1;
    if (direction != bridge->wheelDirection) {
        // Reset fractional progress immediately on reversal.
        bridge->wheelDirection = direction;
        bridge->wheelRemainder = 0;
    }
    bridge->wheelRemainder += __builtin_fabs(vertical);
    if (bridge->wheelRemainder < 1.0) return true;
    bridge->wheelRemainder -= __builtin_floor(bridge->wheelRemainder);
    if (!shouldEmitWheelAction(bridge, direction, nowNs)) return true;

    if (bridge->thumbDown) {
        emitMarker(bridge, direction > 0 ? kActionThumbWheelUp : kActionThumbWheelDown);
    } else {
        bridge->thirdNavigationPending = true;
        emitMarker(bridge, direction > 0 ? kActionThirdWheelUp : kActionThirdWheelDown);
    }
    return true;
}

static bool handleWheel(Bridge *bridge, CGEventRef event) {
    return handleWheelDelta(
        bridge,
        verticalWheelDelta(event),
        (double)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2),
        CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase) != 0,
        monotonicTimeNs());
}

static CGEventRef bridgeEvent(CGEventTapProxy proxy, CGEventType type,
                              CGEventRef event, void *context) {
    (void)proxy;
    Bridge *bridge = context;
    if (bridge->active && getppid() != bridge->parentPID) {
        // The watcher will exit the process. Until then, never suppress input.
        resetAllState(bridge);
        return event;
    }
    if (bridge->active && !receiverHeartbeatHealthy(bridge)) {
        resetAllState(bridge);
        return event; // The watcher will exit; no more events may be suppressed.
    }
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (bridge->active) {
            atomic_store_explicit(
                &bridge->eventLoopExitReason,
                type == kCGEventTapDisabledByTimeout
                    ? kExitTapDisabledByTimeout : kExitTapDisabledByUserInput,
                memory_order_relaxed);
        } else {
            fprintf(stderr, "event tap disabled; stopping to keep all input unchanged\n");
        }
        resetAllState(bridge);
        CFRunLoopStop(CFRunLoopGetCurrent());
        return event;
    }
    if (!event) return event;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) >= kMarkerBase + 1 &&
        CGEventGetIntegerValueField(event, kCGEventSourceUserData) <= kMarkerBase + 10)
        return event; // Never handle our own synthetic F15 events.

    if (IsSecureEventInputEnabled()) {
        resetAllState(bridge);
        return event; // Fail open during Secure Input.
    }

    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        int64_t keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keyCode == kThumbKeyCode || keyCode == kThirdKeyCode) {
            int64_t sourcePID = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
            bool trusted = trustedLogiAgentPID(sourcePID);
            if (!trusted) {
                if (!bridge->active) {
                    fprintf(stdout, "ignore layer F%lld sourcePID=%lld reason=untrusted\n",
                            (long long)(keyCode == kThumbKeyCode ? 13 : 14),
                            (long long)sourcePID);
                    fflush(stdout);
                }
                return event;
            }
            bool down = type == kCGEventKeyDown;
            bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
            if (bridge->layerSourcePID != 0 && bridge->layerSourcePID != (pid_t)sourcePID)
                resetLayerState(bridge);
            bridge->layerSourcePID = (pid_t)sourcePID;
            if (keyCode == kThumbKeyCode) {
                if (!down || !repeat) {
                    if (bridge->thumbDown != down) resetWheelProgress(bridge);
                    bridge->thumbDown = down;
                }
            } else if (!down) {
                bool commit = bridge->thirdNavigationPending;
                bridge->thirdDown = false;
                bridge->thirdNavigationPending = false;
                bridge->thirdLeftDown = false;
                bridge->thirdRightDown = false;
                bridge->thirdBothClicked = false;
                resetWheelProgress(bridge);
                if (commit) emitMarker(bridge, kActionThirdReleaseCommit);
            } else if (!repeat) {
                bridge->thirdDown = true;
                bridge->thirdNavigationPending = false;
                resetWheelProgress(bridge);
            }
            if (!bridge->active) {
                fprintf(stdout, "layer F%lld %s repeat=%d sourcePID=%lld trusted=1\n",
                        (long long)(keyCode == kThumbKeyCode ? 13 : 14),
                        down ? "down" : "up", repeat, (long long)sourcePID);
                fflush(stdout);
            }
        }
        return event; // F13/F14 and all other keyboard input are never consumed.
    }

    if (type != kCGEventLeftMouseDown && type != kCGEventLeftMouseUp &&
        type != kCGEventLeftMouseDragged &&
        type != kCGEventRightMouseDown && type != kCGEventRightMouseUp &&
        type != kCGEventRightMouseDragged &&
        type != kCGEventScrollWheel) return event;

    if (bridge->layerSourcePID != 0 && !trustedLogiAgentPID(bridge->layerSourcePID))
        resetLayerState(bridge);

    uint64_t senderID = eventSenderID(event);
    bool verifiedPhysicalMX = senderID != 0 && verifiedMXSender(bridge, senderID);
    int64_t sourcePID = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    bool trustedSource = senderID == 0 && type == kCGEventScrollWheel &&
                         trustedLogiAgentPID(sourcePID);
    LogitechPointerInventory inventory = {0};
    if (trustedSource) inventory = connectedLogitechPointers();
    PointerOrigin origin = classifyPointerOrigin(type, senderID, verifiedPhysicalMX,
                                                 trustedSource, inventory);
    bool isMX = origin != kOriginUnverified;
    if (!bridge->active && type == kCGEventScrollWheel) {
        fprintf(stdout, "scroll sender=%llu sourcePID=%lld vertical=%.3f origin=%d logiPointers=%u soleMX=%d t_ns=%llu\n",
                (unsigned long long)senderID, (long long)sourcePID,
                verticalWheelDelta(event), origin, inventory.logitechPointingCount,
                inventory.solePointingDeviceIsMX,
                (unsigned long long)monotonicTimeNs());
        fflush(stdout);
    }
    if (!isMX) {
        if (!bridge->active) {
            fprintf(stdout, "pass type=%d sender=%llu sourcePID=%lld reason=unverified\n",
                    (int)type, (unsigned long long)senderID, (long long)sourcePID);
            fflush(stdout);
        }
        return event;
    }

    bool consume;
    if (type == kCGEventScrollWheel) consume = handleWheel(bridge, event);
    else if (type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged)
        consume = handleDrag(bridge, type, senderID);
    else consume = handleClick(bridge, type, senderID);
    if (!bridge->active) {
        fprintf(stdout, "%s type=%d sender=%llu\n",
                consume ? "would-suppress" : "pass",
                (int)type, (unsigned long long)senderID);
        fflush(stdout);
    }
    return bridge->active && consume ? NULL : event;
}

int main(int argc, char **argv) {
    bool active = false;
    pid_t parentPID = 0;
    if (argc == 4 && strcmp(argv[1], "--active") == 0 &&
        strcmp(argv[2], "--parent-pid") == 0) {
        char *end = NULL;
        long requestedPID = strtol(argv[3], &end, 10);
        if (requestedPID <= 1 || requestedPID > INT_MAX || !end || *end != '\0') {
            fprintf(stderr, "invalid parent PID\n");
            return 2;
        }
        parentPID = (pid_t)requestedPID;
        active = true;
    }
    else if (argc == 2 && strcmp(argv[1], "--dry-run") == 0) active = false;
    else if (argc == 3 && strcmp(argv[1], "--check-sender") == 0) {
        char *end = NULL;
        uint64_t senderID = strtoull(argv[2], &end, 0);
        if (!senderID || !end || *end != '\0') {
            fprintf(stderr, "invalid sender ID\n");
            return 2;
        }
        Bridge check = {0};
        bool isMX = verifiedMXSender(&check, senderID);
        fprintf(stdout, "sender=%llu verifiedMX=%d\n",
                (unsigned long long)senderID, isMX);
        return isMX ? 0 : 1;
    }
    else if (argc == 3 && strcmp(argv[1], "--check-logi-context") == 0) {
        char *end = NULL;
        long pid = strtol(argv[2], &end, 0);
        if (pid <= 0 || pid > INT_MAX || !end || *end != '\0') {
            fprintf(stderr, "invalid PID\n");
            return 2;
        }
        bool trusted = trustedLogiAgentPID(pid);
        LogitechPointerInventory inventory = connectedLogitechPointers();
        PointerOrigin origin = classifyPointerOrigin(kCGEventScrollWheel, 0, false,
                                                     trusted, inventory);
        fprintf(stdout, "logiPID=%ld trusted=%d inventoryValid=%d logiPointers=%u soleMX=%d sender0ScrollOrigin=%d\n",
                pid, trusted, inventory.valid, inventory.logitechPointingCount,
                inventory.solePointingDeviceIsMX, origin);
        return 0;
    }
    else if (argc != 1) {
        fprintf(stderr, "usage: %s [--dry-run|--active --parent-pid PID|--check-sender ID|--check-logi-context PID]\n", argv[0]);
        return 2;
    }

    bool listenAccess = CGPreflightListenEventAccess();
    bool postAccess = CGPreflightPostEventAccess();
    bool accessibilityAccess = AXIsProcessTrusted();
    if (!active) {
        fprintf(stdout, "permissions listen=%d post=%d accessibility=%d\n",
                listenAccess, postAccess, accessibilityAccess);
        fflush(stdout);
    } else if (!listenAccess || !postAccess || !accessibilityAccess) {
        fprintf(stderr, "active mode requires Input Monitoring and Accessibility/Post Event access for this helper\n");
        return 1;
    }

    int lockFD = -1, parentWatchFD = -1;
    if (active) {
        if (!configureActiveDiagnostics()) {
            fprintf(stderr, "could not configure nonblocking exit diagnostics; refusing active mode\n");
            return 1;
        }
        if (!trustedHammerspoonParent(parentPID)) {
            fprintf(stderr, "active mode requires the specified, live Hammerspoon parent\n");
            return 1;
        }
        lockFD = acquireActiveInstanceLock();
        if (lockFD < 0) {
            fprintf(stderr, "another active MX4 helper is running or the lock is unavailable\n");
            return 1;
        }
        parentWatchFD = registerParentExitWatch(parentPID);
        if (parentWatchFD < 0) {
            fprintf(stderr, "could not monitor Hammerspoon parent; refusing active mode\n");
            close(lockFD);
            return 1;
        }
        int stdinFlags = fcntl(STDIN_FILENO, F_GETFL);
        if (stdinFlags < 0 || fcntl(STDIN_FILENO, F_SETFL, stdinFlags | O_NONBLOCK) != 0) {
            fprintf(stderr, "could not configure receiver heartbeat input; refusing active mode\n");
            close(parentWatchFD);
            close(lockFD);
            return 1;
        }
    }

    Bridge bridge = { .active = active, .parentPID = parentPID };
    if (active) {
        uint64_t startNs = monotonicTimeNs();
        if (startNs == 0) {
            fprintf(stderr, "monotonic clock unavailable; refusing active mode\n");
            close(parentWatchFD);
            close(lockFD);
            return 1;
        }
        atomic_store_explicit(&bridge.lastHeartbeatTimeNs, startNs, memory_order_relaxed);
    }
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
                       CGEventMaskBit(kCGEventKeyUp) |
                       CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventRightMouseDown) |
                       CGEventMaskBit(kCGEventRightMouseUp) |
                       CGEventMaskBit(kCGEventRightMouseDragged) |
                       CGEventMaskBit(kCGEventScrollWheel);
    bridge.tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                  active ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly,
                                  mask, bridgeEvent, &bridge);
    if (!bridge.tap) {
        fprintf(stderr, "Could not create %s event tap; grant required macOS input permissions\n",
                active ? "active" : "listen-only");
        if (parentWatchFD >= 0) close(parentWatchFD);
        if (lockFD >= 0) close(lockFD);
        return 1;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, bridge.tap, 0);
    if (!source) {
        fprintf(stderr, "Could not create event tap run-loop source\n");
        CFRelease(bridge.tap);
        if (parentWatchFD >= 0) close(parentWatchFD);
        if (lockFD >= 0) close(lockFD);
        return 1;
    }

    pthread_t watcher;
    pthread_t heartbeatWatcher;
    if (active) {
        if (pthread_create(&watcher, NULL, watchParentExit, &parentWatchFD) != 0) {
            fprintf(stderr, "could not start Hammerspoon parent watcher; refusing active mode\n");
            CFRelease(source);
            CFRelease(bridge.tap);
            close(parentWatchFD);
            close(lockFD);
            return 1;
        }
        pthread_detach(watcher);
        if (pthread_create(&heartbeatWatcher, NULL, watchReceiverHeartbeat, &bridge) != 0) {
            fprintf(stderr, "could not start receiver heartbeat watcher; refusing active mode\n");
            CFRelease(source);
            CFRelease(bridge.tap);
            close(parentWatchFD);
            close(lockFD);
            return 1;
        }
        pthread_detach(heartbeatWatcher);
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(bridge.tap, true);
    if (active && !CGEventTapIsEnabled(bridge.tap)) {
        fprintf(stderr, "event tap disabled at startup; refusing active mode\n");
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CFRelease(source);
        CFRelease(bridge.tap);
        close(parentWatchFD);
        close(lockFD);
        return 1;
    }
    fprintf(stdout, "MX4 helper ready: %s (F13/F14 observed, all unknown senders pass)\n",
            active ? "ACTIVE" : "DRY RUN / NO INPUT CHANGES");
    fflush(stdout);
    CFRunLoopRun();
    if (active) {
        int reason = atomic_load_explicit(&bridge.eventLoopExitReason,
                                           memory_order_relaxed);
        reportActiveExit(eventLoopExitReasonName((EventLoopExitReason)reason));
    }
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CFRelease(bridge.tap);
    if (parentWatchFD >= 0) close(parentWatchFD);
    if (lockFD >= 0) close(lockFD);
    return 0;
}
