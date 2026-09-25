#define MX4_TESTING 1
#define main mx4_helper_main
#include "mx4-device-helper.m"
#undef main

#include <assert.h>
#include <signal.h>
#include <sys/wait.h>

static void testClassifier(void) {
    LogitechPointerInventory soleMX = { .valid = true, .logitechPointingCount = 1,
                                        .solePointingDeviceIsMX = true };
    LogitechPointerInventory twoPointers = { .valid = true, .logitechPointingCount = 2,
                                             .solePointingDeviceIsMX = false };
    LogitechPointerInventory noInventory = {0};
    assert(classifyPointerOrigin(kCGEventScrollWheel, 4295205572ULL, true,
                                 false, noInventory) == kOriginPhysicalMX);
    assert(classifyPointerOrigin(kCGEventLeftMouseDown, 4295205572ULL, true,
                                 false, noInventory) == kOriginPhysicalMX);
    assert(classifyPointerOrigin(kCGEventScrollWheel, 4294970477ULL, false,
                                 true, soleMX) == kOriginUnverified);
    assert(classifyPointerOrigin(kCGEventScrollWheel, 0, false,
                                 true, soleMX) == kOriginLogiInferredMX);
    assert(classifyPointerOrigin(kCGEventScrollWheel, 0, false,
                                 false, soleMX) == kOriginUnverified);
    assert(classifyPointerOrigin(kCGEventScrollWheel, 0, false,
                                 true, twoPointers) == kOriginUnverified);
    assert(classifyPointerOrigin(kCGEventScrollWheel, 0, false,
                                 true, noInventory) == kOriginUnverified);
    assert(classifyPointerOrigin(kCGEventLeftMouseDown, 0, false,
                                 true, soleMX) == kOriginUnverified);
}

static void testNegativeSenderCache(void) {
    Bridge bridge = {0};
    bridge.cache[0] = (SenderCacheEntry){ .senderID = 4294970477ULL,
                                         .isMX = false, .occupied = true };
    bridge.cache[1] = (SenderCacheEntry){ .senderID = 4295205572ULL,
                                         .isMX = true, .occupied = true };
    assert(cachedNonMXSender(&bridge, 4294970477ULL));
    assert(!cachedNonMXSender(&bridge, 4295205572ULL));
    assert(!cachedNonMXSender(&bridge, 0));
    assert(!cachedNonMXSender(&bridge, 42));
    // A cached negative result fails closed without consulting a disappearing
    // or unrelated IORegistry service.
    assert(!verifiedMXSender(&bridge, 4294970477ULL));
}

static void testThumbClickPairing(void) {
    Bridge bridge = {0};
    bridge.thumbDown = true;
    assert(handleClick(&bridge, kCGEventLeftMouseDown, 101));
    assert(bridge.emittedActionCount == 1);
    assert(bridge.emittedActions[0] == kActionThumbLeftClose);
    assert(!handleClick(&bridge, kCGEventLeftMouseUp, 202));
    assert(bridge.left.consumed);
    assert(handleDrag(&bridge, kCGEventLeftMouseDragged, 101));
    assert(!handleDrag(&bridge, kCGEventLeftMouseDragged, 202));
    bridge.thumbDown = false;
    assert(handleClick(&bridge, kCGEventLeftMouseUp, 101));
    assert(!bridge.left.consumed);
    assert(bridge.emittedActionCount == 1);
}

static void testThirdClicks(void) {
    Bridge bridge = {0};
    bridge.thirdDown = true;
    assert(handleClick(&bridge, kCGEventLeftMouseDown, 101));
    assert(handleClick(&bridge, kCGEventRightMouseDown, 101));
    assert(bridge.emittedActionCount == 1);
    assert(bridge.emittedActions[0] == kActionThirdSelectAll);
    assert(handleClick(&bridge, kCGEventLeftMouseUp, 101));
    assert(handleClick(&bridge, kCGEventRightMouseUp, 101));
    assert(bridge.emittedActionCount == 1); // No copy/paste after both-click.

    assert(handleClick(&bridge, kCGEventLeftMouseDown, 101));
    assert(handleClick(&bridge, kCGEventLeftMouseUp, 101));
    assert(bridge.emittedActionCount == 2);
    assert(bridge.emittedActions[1] == kActionThirdCopy);

    assert(handleClick(&bridge, kCGEventRightMouseDown, 101));
    assert(handleClick(&bridge, kCGEventRightMouseUp, 101));
    assert(bridge.emittedActionCount == 3);
    assert(bridge.emittedActions[2] == kActionThirdPaste);
}

static void testActiveLifetimeGuards(void) {
    int first = acquireActiveInstanceLock();
    assert(first >= 0);
    int second = acquireActiveInstanceLock();
    assert(second < 0);
    close(first);
    int afterRelease = acquireActiveInstanceLock();
    assert(afterRelease >= 0);
    close(afterRelease);

    int parentWatch = registerParentExitWatch(getppid());
    assert(parentWatch >= 0);
    close(parentWatch);
    assert(!trustedHammerspoonParent(getppid()));
}

static void testThumbWheelCoalescingAndImmediateReversal(void) {
    Bridge bridge = {0};
    bridge.thumbDown = true;
    const uint64_t start = 1000000000ULL;
    assert(handleWheelDelta(&bridge, 1, 0, false, start));
    assert(bridge.emittedActionCount == 1);
    assert(bridge.emittedActions[0] == kActionThumbWheelUp);

    assert(handleWheelDelta(&bridge, 1, 0, false, start + 20000000ULL));
    assert(handleWheelDelta(&bridge, 1, 0, false, start + 54999999ULL));
    assert(bridge.emittedActionCount == 1); // Same-direction burst coalesced.

    assert(handleWheelDelta(&bridge, 1, 0, false, start + 55000000ULL));
    assert(bridge.emittedActionCount == 2);
    assert(bridge.emittedActions[1] == kActionThumbWheelUp);

    assert(handleWheelDelta(&bridge, -1, 0, false, start + 55000001ULL));
    assert(bridge.emittedActionCount == 3);
    assert(bridge.emittedActions[2] == kActionThumbWheelDown);

    assert(handleWheelDelta(&bridge, 1, 0, false, start + 55000002ULL));
    assert(bridge.emittedActionCount == 4);
    assert(bridge.emittedActions[3] == kActionThumbWheelUp);

    resetWheelProgress(&bridge);
    assert(handleWheelDelta(&bridge, 1, 0, false, start + 55000003ULL));
    assert(bridge.emittedActionCount == 5); // New hold is not throttled by old hold.
}

static void testThirdWheelCoalescingAndFilteredImpulses(void) {
    Bridge bridge = {0};
    bridge.thirdDown = true;
    const uint64_t start = 2000000000ULL;
    assert(!handleWheelDelta(&bridge, 0, 4, false, start));
    assert(!handleWheelDelta(&bridge, 1, 4, false, start));
    assert(handleWheelDelta(&bridge, 1, 0, true, start));
    assert(bridge.emittedActionCount == 0);

    assert(handleWheelDelta(&bridge, 1, 0, false, start));
    assert(bridge.emittedActionCount == 1);
    assert(bridge.emittedActions[0] == kActionThirdWheelUp);
    assert(bridge.thirdNavigationPending);
    assert(handleWheelDelta(&bridge, 1, 0, false, start + 109000000ULL));
    assert(bridge.emittedActionCount == 1);
    assert(handleWheelDelta(&bridge, -1, 0, false, start + 109000001ULL));
    assert(bridge.emittedActionCount == 2); // Reverse within 110 ms is accepted.
    assert(bridge.emittedActions[1] == kActionThirdWheelDown);
    assert(handleWheelDelta(&bridge, -1, 0, false, start + 219000001ULL));
    assert(bridge.emittedActionCount == 3);
    assert(bridge.emittedActions[2] == kActionThirdWheelDown);
}

static void testFractionalWheelReversal(void) {
    Bridge bridge = {0};
    bridge.thumbDown = true;
    const uint64_t start = 3000000000ULL;
    assert(handleWheelDelta(&bridge, 0.4, 0, false, start));
    assert(bridge.emittedActionCount == 0);
    assert(handleWheelDelta(&bridge, 0.7, 0, false, start + 1000000ULL));
    assert(bridge.emittedActionCount == 1);
    assert(handleWheelDelta(&bridge, -0.5, 0, false, start + 2000000ULL));
    assert(bridge.emittedActionCount == 1);
    assert(handleWheelDelta(&bridge, -0.5, 0, false, start + 3000000ULL));
    assert(bridge.emittedActionCount == 2);
    assert(bridge.emittedActions[1] == kActionThumbWheelDown);
}

static bool childExitedWithin(pid_t child, unsigned timeoutMs) {
    for (unsigned elapsed = 0; elapsed < timeoutMs; elapsed += 10) {
        int status = 0;
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) return WIFEXITED(status) && WEXITSTATUS(status) == 0;
        if (result < 0) return false;
        usleep(10000);
    }
    kill(child, SIGKILL); // Only our isolated test child.
    waitpid(child, NULL, 0);
    return false;
}

static bool childStaysRunningFor(pid_t child, unsigned durationMs) {
    for (unsigned elapsed = 0; elapsed < durationMs; elapsed += 10) {
        int status = 0;
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result != 0) return false;
        usleep(10000);
    }
    return true;
}

static void testHeartbeatTimeoutMath(void) {
    const uint64_t last = 10000000000ULL;
    assert(!receiverHeartbeatExpired(last, last));
    assert(!receiverHeartbeatExpired(last, last + kReceiverHeartbeatTimeoutNs - 1));
    assert(receiverHeartbeatExpired(last, last + kReceiverHeartbeatTimeoutNs));
    assert(receiverHeartbeatExpired(0, last));
    assert(receiverHeartbeatExpired(last, 0));
    assert(receiverHeartbeatExpired(last, last - 1));
    // A newly received byte renews the deadline for a full three seconds.
    const uint64_t renewed = last + 2500000000ULL;
    assert(!receiverHeartbeatExpired(renewed, last + kReceiverHeartbeatTimeoutNs));
}

static void testHeartbeatWatcherEOFAndTimeout(void) {
    int input[2];
    assert(pipe(input) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(input[1]);
        assert(dup2(input[0], STDIN_FILENO) >= 0);
        if (input[0] != STDIN_FILENO) close(input[0]);
        Bridge bridge = {0};
        atomic_store(&bridge.lastHeartbeatTimeNs, monotonicTimeNs());
        watchReceiverHeartbeat(&bridge);
        _exit(99);
    }
    close(input[0]);
    close(input[1]); // EOF must stop the watcher promptly, before three seconds.
    assert(childExitedWithin(child, 1000));

    assert(pipe(input) == 0);
    child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(input[1]);
        assert(dup2(input[0], STDIN_FILENO) >= 0);
        if (input[0] != STDIN_FILENO) close(input[0]);
        Bridge bridge = {0};
        atomic_store(&bridge.lastHeartbeatTimeNs,
                     monotonicTimeNs() - kReceiverHeartbeatTimeoutNs + 100000000ULL);
        watchReceiverHeartbeat(&bridge);
        _exit(99);
    }
    close(input[0]);
    assert(childExitedWithin(child, 1000)); // Writer stays open: timeout, not EOF.
    close(input[1]);

    assert(pipe(input) == 0);
    child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(input[1]);
        assert(dup2(input[0], STDIN_FILENO) >= 0);
        if (input[0] != STDIN_FILENO) close(input[0]);
        Bridge bridge = {0};
        // With no byte, this child would time out after one second.
        atomic_store(&bridge.lastHeartbeatTimeNs,
                     monotonicTimeNs() - kReceiverHeartbeatTimeoutNs + 1000000000ULL);
        watchReceiverHeartbeat(&bridge);
        _exit(99);
    }
    close(input[0]);
    assert(write(input[1], ".", 1) == 1);
    assert(childStaysRunningFor(child, 1200)); // Byte renewed the deadline.
    close(input[1]);
    assert(childExitedWithin(child, 1000)); // EOF still stops it promptly.
}

static void testNonblockingExitDiagnostics(void) {
    assert(strcmp(eventLoopExitReasonName(kExitTapDisabledByTimeout),
                  "event_tap_disabled_by_timeout") == 0);
    assert(strcmp(eventLoopExitReasonName(kExitTapDisabledByUserInput),
                  "event_tap_disabled_by_user_input") == 0);
    assert(strcmp(eventLoopExitReasonName(kExitLoopUnknown),
                  "event_loop_stopped") == 0);

    int output[2];
    assert(pipe(output) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(output[0]);
        assert(dup2(output[1], STDERR_FILENO) >= 0);
        if (output[1] != STDERR_FILENO) close(output[1]);
        assert(configureActiveDiagnostics());
        reportActiveExit("receiver_heartbeat_timeout");
        reportActiveExit("event_loop_stopped"); // Never emit a second reason.
        _exit(0);
    }
    close(output[1]);
    assert(childExitedWithin(child, 1000));
    char line[160] = {0};
    ssize_t count = read(output[0], line, sizeof(line) - 1);
    close(output[0]);
    assert(count > 0);
    assert(strcmp(line, "MX4 helper exit: receiver_heartbeat_timeout\n") == 0);
}

int main(void) {
    testClassifier();
    testNegativeSenderCache();
    testThumbClickPairing();
    testThirdClicks();
    testActiveLifetimeGuards();
    testThumbWheelCoalescingAndImmediateReversal();
    testThirdWheelCoalescingAndFilteredImpulses();
    testFractionalWheelReversal();
    testHeartbeatTimeoutMath();
    testHeartbeatWatcherEOFAndTimeout();
    testNonblockingExitDiagnostics();
    puts("MX4 helper classifier, click, wheel, heartbeat, and exit diagnostic tests passed");
    return 0;
}
