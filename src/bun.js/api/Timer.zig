const std = @import("std");
const bun = @import("root").bun;
const JSC = bun.JSC;
const VirtualMachine = JSC.VirtualMachine;
const JSValue = JSC.JSValue;
const JSGlobalObject = JSC.JSGlobalObject;
const Debugger = JSC.Debugger;
const Environment = bun.Environment;
const Async = @import("async");
const uv = bun.windows.libuv;
const StatWatcherScheduler = @import("../node/node_fs_stat_watcher.zig").StatWatcherScheduler;
const Timer = @This();
const DNSResolver = @import("./bun/dns_resolver.zig").DNSResolver;

/// TimeoutMap is map of i32 to nullable Timeout structs
/// i32 is exposed to JavaScript and can be used with clearTimeout, clearInterval, etc.
/// When Timeout is null, it means the tasks have been scheduled but not yet executed.
/// Timeouts are enqueued as a task to be run on the next tick of the task queue
/// The task queue runs after the event loop tasks have been run
/// Therefore, there is a race condition where you cancel the task after it has already been enqueued
/// In that case, it shouldn't run. It should be skipped.
pub const TimeoutMap = std.AutoArrayHashMapUnmanaged(
    i32,
    *EventLoopTimer,
);

const TimerHeap = heap.Intrusive(EventLoopTimer, void, EventLoopTimer.less);

pub const All = struct {
    last_id: i32 = 1,
    timers: TimerHeap = .{
        .context = {},
    },
    active_timer_count: i32 = 0,
    uv_timer: if (Environment.isWindows) uv.Timer else void = if (Environment.isWindows) std.mem.zeroes(uv.Timer),

    // We split up the map here to avoid storing an extra "repeat" boolean
    maps: struct {
        setTimeout: TimeoutMap = .{},
        setInterval: TimeoutMap = .{},
        setImmediate: TimeoutMap = .{},

        pub inline fn get(this: *@This(), kind: Kind) *TimeoutMap {
            return switch (kind) {
                .setTimeout => &this.setTimeout,
                .setInterval => &this.setInterval,
                .setImmediate => &this.setImmediate,
            };
        }
    } = .{},

    pub fn insert(this: *All, timer: *EventLoopTimer) void {
        this.timers.insert(timer);
        timer.state = .ACTIVE;

        if (Environment.isWindows) {
            this.ensureUVTimer(@alignCast(@fieldParentPtr("timer", this)));
        }
    }

    pub fn remove(this: *All, timer: *EventLoopTimer) void {
        this.timers.remove(timer);

        timer.state = .CANCELLED;
        timer.heap = .{};
    }

    fn ensureUVTimer(this: *All, vm: *VirtualMachine) void {
        if (this.uv_timer.data == null) {
            this.uv_timer.init(vm.uvLoop());
            this.uv_timer.data = vm;
            this.uv_timer.unref();
        }

        if (this.timers.peek()) |timer| {
            uv.uv_update_time(vm.uvLoop());
            const now = timespec.now();
            const wait = if (timer.next.greater(&now))
                timer.next.duration(&now)
            else
                timespec{ .nsec = 0, .sec = 0 };

            this.uv_timer.start(wait.msUnsigned(), 0, &onUVTimer);

            if (this.active_timer_count > 0) {
                this.uv_timer.ref();
            } else {
                this.uv_timer.unref();
            }
        }
    }

    pub fn onUVTimer(uv_timer_t: *uv.Timer) callconv(.C) void {
        const all: *All = @fieldParentPtr("uv_timer", uv_timer_t);
        const vm: *VirtualMachine = @alignCast(@fieldParentPtr("timer", all));
        all.drainTimers(vm);
        all.ensureUVTimer(vm);
    }

    pub fn incrementTimerRef(this: *All, delta: i32) void {
        const vm: *JSC.VirtualMachine = @alignCast(@fieldParentPtr("timer", this));

        const old = this.active_timer_count;
        const new = old + delta;

        if (comptime Environment.isDebug) {
            assert(new >= 0);
        }

        this.active_timer_count = new;

        if (old <= 0 and new > 0) {
            if (comptime Environment.isWindows) {
                this.uv_timer.ref();
            } else {
                vm.uwsLoop().ref();
            }
        } else if (old > 0 and new <= 0) {
            if (comptime Environment.isWindows) {
                this.uv_timer.unref();
            } else {
                vm.uwsLoop().unref();
            }
        }
    }

    pub fn getNextID() callconv(.C) i32 {
        VirtualMachine.get().timer.last_id +%= 1;
        return VirtualMachine.get().timer.last_id;
    }

    pub fn getTimeout(this: *const All, spec: *timespec) bool {
        if (this.active_timer_count == 0) {
            return false;
        }

        if (this.timers.peek()) |min| {
            const now = timespec.now();
            switch (now.order(&min.next)) {
                .gt, .eq => {
                    spec.* = .{ .nsec = 0, .sec = 0 };
                    return true;
                },
                .lt => {
                    spec.* = min.next.duration(&now);
                    return true;
                },
            }
        }

        return false;
    }

    export fn Bun__internal_drainTimers(vm: *VirtualMachine) callconv(.C) void {
        drainTimers(&vm.timer, vm);
    }

    comptime {
        _ = &Bun__internal_drainTimers;
    }

    pub fn drainTimers(this: *All, vm: *VirtualMachine) void {
        if (this.timers.peek() == null) {
            return;
        }

        const now = &timespec.now();

        while (this.timers.peek()) |t| {
            if (t.next.greater(now)) {
                break;
            }

            assert(this.timers.deleteMin().? == t);

            switch (t.fire(
                now,
                vm,
            )) {
                .disarm => {},
                .rearm => {},
            }
        }
    }

    fn set(
        id: i32,
        globalThis: *JSGlobalObject,
        callback: JSValue,
        interval: i32,
        arguments_array_or_zero: JSValue,
        repeat: bool,
    ) !JSC.JSValue {
        JSC.markBinding(@src());
        var vm = globalThis.bunVM();

        const kind: Kind = if (repeat) .setInterval else .setTimeout;

        // setImmediate(foo)
        if (kind == .setTimeout and interval == 0) {
            const immediate_object, const js = ImmediateObject.init(globalThis, id, callback, arguments_array_or_zero);
            immediate_object.ref();
            vm.enqueueImmediateTask(JSC.Task.init(immediate_object));
            if (vm.isInspectorEnabled()) {
                Debugger.didScheduleAsyncCall(globalThis, .DOMTimer, ID.asyncID(.{ .id = id, .kind = kind }), !repeat);
            }
            return js;
        } else {
            _, const js = TimeoutObject.init(globalThis, id, kind, interval, callback, arguments_array_or_zero);

            if (vm.isInspectorEnabled()) {
                Debugger.didScheduleAsyncCall(globalThis, .DOMTimer, ID.asyncID(.{ .id = id, .kind = kind }), !repeat);
            }

            return js;
        }
    }

    pub fn setImmediate(
        globalThis: *JSGlobalObject,
        callback: JSValue,
        arguments: JSValue,
    ) callconv(.C) JSValue {
        JSC.markBinding(@src());
        const id = globalThis.bunVM().timer.last_id;
        globalThis.bunVM().timer.last_id +%= 1;

        const interval: i32 = 0;

        const wrappedCallback = callback.withAsyncContextIfNeeded(globalThis);

        return set(id, globalThis, wrappedCallback, interval, arguments, false) catch
            return JSValue.jsUndefined();
    }

    comptime {
        if (!JSC.is_bindgen) {
            @export(setImmediate, .{ .name = "Bun__Timer__setImmediate" });
        }
    }

    pub fn setTimeout(
        globalThis: *JSGlobalObject,
        callback: JSValue,
        countdown: JSValue,
        arguments: JSValue,
        saturateTimeoutOnOverflowInsteadOfZeroing: bool,
    ) callconv(.C) JSValue {
        JSC.markBinding(@src());
        const id = globalThis.bunVM().timer.last_id;
        globalThis.bunVM().timer.last_id +%= 1;

        // TODO: this is wrong as it clears exceptions
        const countdown_double = countdown.coerceToDouble(globalThis);

        const countdown_int: i32 = if (saturateTimeoutOnOverflowInsteadOfZeroing)
            std.math.lossyCast(i32, countdown_double)
        else
            (if (!std.math.isFinite(countdown_double))
                1
            else if (countdown_double < std.math.minInt(i32) or countdown_double > std.math.maxInt(i32))
                1
            else
                @max(1, @as(i32, @intFromFloat(countdown_double))));

        const wrappedCallback = callback.withAsyncContextIfNeeded(globalThis);

        return set(id, globalThis, wrappedCallback, countdown_int, arguments, false) catch
            return JSValue.jsUndefined();
    }
    pub fn setInterval(
        globalThis: *JSGlobalObject,
        callback: JSValue,
        countdown: JSValue,
        arguments: JSValue,
    ) callconv(.C) JSValue {
        JSC.markBinding(@src());
        const id = globalThis.bunVM().timer.last_id;
        globalThis.bunVM().timer.last_id +%= 1;

        const wrappedCallback = callback.withAsyncContextIfNeeded(globalThis);

        // We don't deal with nesting levels directly
        // but we do set the minimum timeout to be 1ms for repeating timers
        // TODO: this is wrong as it clears exceptions
        const countdown_double = countdown.coerceToDouble(globalThis);

        const countdown_int: i32 = if (!std.math.isFinite(countdown_double))
            1
        else if (countdown_double < std.math.minInt(i32) or countdown_double > std.math.maxInt(i32))
            1
        else
            @max(1, @as(i32, @intFromFloat(countdown_double)));

        return set(id, globalThis, wrappedCallback, countdown_int, arguments, true) catch
            return JSValue.jsUndefined();
    }

    fn removeTimerById(this: *All, id: i32) ?*TimeoutObject {
        if (this.maps.setTimeout.fetchSwapRemove(id)) |entry| {
            bun.assert(entry.value.tag == .TimeoutObject);
            return @fieldParentPtr("event_loop_timer", entry.value);
        } else if (this.maps.setInterval.fetchSwapRemove(id)) |entry| {
            bun.assert(entry.value.tag == .TimeoutObject);
            return @fieldParentPtr("event_loop_timer", entry.value);
        } else return null;
    }

    pub fn clearTimer(timer_id_value: JSValue, globalThis: *JSGlobalObject) void {
        JSC.markBinding(@src());

        const vm = globalThis.bunVM();

        const timer: *TimerObjectInternals = brk: {
            if (timer_id_value.isInt32()) {
                // Immediates don't have numeric IDs in Node.js so we only have to look up timeouts and intervals
                break :brk &(vm.timer.removeTimerById(timer_id_value.asInt32()) orelse return).internals;
            } else if (timer_id_value.isStringLiteral()) {
                const string = timer_id_value.toBunString2(globalThis) catch return;
                defer string.deref();
                // Custom parseInt logic. I've done this because Node.js is very strict about string
                // parameters to this function: they can't have leading whitespace, trailing
                // characters, signs, or even leading zeroes.
                //
                // The reason is that in Node.js this function's parameter is used for an array
                // lookup, and array[0] is the same as array['0'] in JS but not the same as array['00'].
                const parsed = parsed: {
                    var accumulator: i32 = 0;
                    switch (string.encoding()) {
                        // We can handle all encodings the same way since the only permitted characters
                        // are ASCII.
                        inline else => |encoding| {
                            const slice = @field(bun.String, @tagName(encoding))(string);
                            for (slice, 0..) |c, i| {
                                if (c < '0' or c > '9') {
                                    // Non-digit characters are not allowed
                                    return;
                                } else if (i == 0 and c == '0') {
                                    // Leading zeroes are not allowed
                                    return;
                                }
                                accumulator *= 10;
                                accumulator += c - '0';
                            }
                        },
                    }
                    break :parsed accumulator;
                };
                break :brk &(vm.timer.removeTimerById(parsed) orelse return).internals;
            }

            break :brk if (TimeoutObject.fromJS(timer_id_value)) |timeout|
                &timeout.internals
            else if (ImmediateObject.fromJS(timer_id_value)) |immediate|
                &immediate.internals
            else
                null;
        } orelse return;

        timer.cancel(vm);
    }

    pub fn clearTimeout(
        globalThis: *JSGlobalObject,
        id: JSValue,
    ) callconv(.C) JSValue {
        JSC.markBinding(@src());
        clearTimer(id, globalThis);
        return JSValue.jsUndefined();
    }
    pub fn clearInterval(
        globalThis: *JSGlobalObject,
        id: JSValue,
    ) callconv(.C) JSValue {
        JSC.markBinding(@src());
        clearTimer(id, globalThis);
        return JSValue.jsUndefined();
    }

    const Shimmer = @import("../bindings/shimmer.zig").Shimmer;

    pub const shim = Shimmer("Bun", "Timer", @This());
    pub const name = "Bun__Timer";
    pub const include = "";
    pub const namespace = shim.namespace;

    pub const Export = shim.exportFunctions(.{
        .setTimeout = setTimeout,
        .setInterval = setInterval,
        .clearTimeout = clearTimeout,
        .clearInterval = clearInterval,
        .getNextID = getNextID,
    });

    comptime {
        if (!JSC.is_bindgen) {
            @export(setTimeout, .{ .name = Export[0].symbol_name });
            @export(setInterval, .{ .name = Export[1].symbol_name });
            @export(clearTimeout, .{ .name = Export[2].symbol_name });
            @export(clearInterval, .{ .name = Export[3].symbol_name });
            @export(getNextID, .{ .name = Export[4].symbol_name });
        }
    }
};

const uws = bun.uws;

pub const TimeoutObject = struct {
    event_loop_timer: EventLoopTimer = .{
        .next = .{},
        .tag = .TimeoutObject,
    },
    internals: TimerObjectInternals,
    ref_count: u32 = 1,

    pub usingnamespace JSC.Codegen.JSTimeout;
    pub usingnamespace bun.NewRefCounted(@This(), deinit);

    pub fn init(
        globalThis: *JSGlobalObject,
        id: i32,
        kind: Kind,
        interval: i32,
        callback: JSValue,
        arguments_array_or_zero: JSValue,
    ) struct { *TimeoutObject, JSValue } {
        // internals are initialized by init()
        const timeout = TimeoutObject.new(.{ .internals = undefined });
        const js = timeout.toJS(globalThis);
        defer js.ensureStillAlive();
        timeout.internals.init(
            js,
            globalThis,
            id,
            kind,
            interval,
            callback,
            arguments_array_or_zero,
        );
        return .{ timeout, js };
    }

    pub fn deinit(this: *TimeoutObject) void {
        this.internals.deinit();
    }

    pub fn constructor(globalObject: *JSC.JSGlobalObject, callFrame: *JSC.CallFrame) !*TimeoutObject {
        _ = callFrame;
        return globalObject.throw("Timeout is not constructible", .{});
    }

    pub fn runImmediateTask(this: *TimeoutObject, vm: *VirtualMachine) void {
        this.internals.runImmediateTask(vm);
    }

    pub fn toPrimitive(this: *TimeoutObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.toPrimitive(globalThis, callFrame);
    }

    pub fn doRef(this: *TimeoutObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.doRef(globalThis, callFrame);
    }

    pub fn doUnref(this: *TimeoutObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.doUnref(globalThis, callFrame);
    }

    pub fn doRefresh(this: *TimeoutObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.doRefresh(globalThis, callFrame);
    }

    pub fn hasRef(this: *TimeoutObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.hasRef(globalThis, callFrame);
    }

    pub fn finalize(this: *TimeoutObject) void {
        this.internals.finalize();
    }
};

pub const ImmediateObject = struct {
    event_loop_timer: EventLoopTimer = .{
        .next = .{},
        .tag = .ImmediateObject,
    },
    internals: TimerObjectInternals,
    ref_count: u32 = 1,

    pub usingnamespace JSC.Codegen.JSImmediate;
    pub usingnamespace bun.NewRefCounted(@This(), deinit);

    pub fn init(
        globalThis: *JSGlobalObject,
        id: i32,
        callback: JSValue,
        arguments_array_or_zero: JSValue,
    ) struct { *ImmediateObject, JSValue } {
        // internals are initialized by init()
        const immediate = ImmediateObject.new(.{ .internals = undefined });
        const js = immediate.toJS(globalThis);
        defer js.ensureStillAlive();
        immediate.internals.init(
            js,
            globalThis,
            id,
            .setImmediate,
            0,
            callback,
            arguments_array_or_zero,
        );
        return .{ immediate, js };
    }

    pub fn deinit(this: *ImmediateObject) void {
        this.internals.deinit();
    }

    pub fn constructor(globalObject: *JSC.JSGlobalObject, callFrame: *JSC.CallFrame) !*ImmediateObject {
        _ = callFrame;
        return globalObject.throw("Immediate is not constructible", .{});
    }

    pub fn runImmediateTask(this: *ImmediateObject, vm: *VirtualMachine) void {
        this.internals.runImmediateTask(vm);
    }

    pub fn toPrimitive(this: *ImmediateObject, globalThis: *JSC.JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.toPrimitive(globalThis, callFrame);
    }

    pub fn doRef(this: *ImmediateObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.doRef(globalThis, callFrame);
    }

    pub fn doUnref(this: *ImmediateObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.doUnref(globalThis, callFrame);
    }

    pub fn doRefresh(this: *ImmediateObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.doRefresh(globalThis, callFrame);
    }

    pub fn hasRef(this: *ImmediateObject, globalThis: *JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        return this.internals.hasRef(globalThis, callFrame);
    }

    pub fn finalize(this: *ImmediateObject) void {
        this.internals.finalize();
    }
};

/// Data that TimerObject and ImmediateObject have in common
const TimerObjectInternals = struct {
    id: i32 = -1,
    kind: Kind = .setTimeout,
    interval: i32 = 0,
    // we do not allow the timer to be refreshed after we call clearInterval/clearTimeout
    has_cleared_timer: bool = false,
    is_keeping_event_loop_alive: bool = false,

    // if they never access the timer by integer, don't create a hashmap entry.
    has_accessed_primitive: bool = false,

    strong_this: JSC.Strong = .{},

    has_js_ref: bool = true,

    fn eventLoopTimer(this: *TimerObjectInternals) *EventLoopTimer {
        switch (this.kind) {
            .setImmediate => {
                const parent: *ImmediateObject = @fieldParentPtr("internals", this);
                assert(parent.event_loop_timer.tag == .ImmediateObject);
                return &parent.event_loop_timer;
            },
            .setTimeout, .setInterval => {
                const parent: *TimeoutObject = @fieldParentPtr("internals", this);
                assert(parent.event_loop_timer.tag == .TimeoutObject);
                return &parent.event_loop_timer;
            },
        }
    }

    fn ref(this: *TimerObjectInternals) void {
        switch (this.kind) {
            .setImmediate => @as(*ImmediateObject, @fieldParentPtr("internals", this)).ref(),
            .setTimeout, .setInterval => @as(*TimeoutObject, @fieldParentPtr("internals", this)).ref(),
        }
    }

    fn deref(this: *TimerObjectInternals) void {
        switch (this.kind) {
            .setImmediate => @as(*ImmediateObject, @fieldParentPtr("internals", this)).deref(),
            .setTimeout, .setInterval => @as(*TimeoutObject, @fieldParentPtr("internals", this)).deref(),
        }
    }

    extern "C" fn Bun__JSTimeout__call(encodedTimeoutValue: JSValue, globalObject: *JSC.JSGlobalObject) void;

    pub fn runImmediateTask(this: *TimerObjectInternals, vm: *VirtualMachine) void {
        if (this.has_cleared_timer) {
            this.deref();
            return;
        }

        const this_object = this.strong_this.get() orelse {
            if (Environment.isDebug) {
                @panic("TimerObjectInternals.runImmediateTask: this_object is null");
            }
            return;
        };
        const globalThis = this.strong_this.globalThis.?;
        this.strong_this.deinit();
        this.eventLoopTimer().state = .FIRED;

        vm.eventLoop().enter();
        {
            this.ref();
            defer this.deref();

            run(this_object, globalThis, this.asyncID(), vm);

            if (this.eventLoopTimer().state == .FIRED) {
                this.deref();
            }
        }
        vm.eventLoop().exit();
    }

    pub fn asyncID(this: *const TimerObjectInternals) u64 {
        return ID.asyncID(.{ .id = this.id, .kind = this.kind });
    }

    pub fn fire(this: *TimerObjectInternals, _: *const timespec, vm: *JSC.VirtualMachine) EventLoopTimer.Arm {
        const id = this.id;
        const kind = this.kind;
        const has_been_cleared = this.eventLoopTimer().state == .CANCELLED or this.has_cleared_timer or vm.scriptExecutionStatus() != .running;

        this.eventLoopTimer().state = .FIRED;
        this.eventLoopTimer().heap = .{};

        if (has_been_cleared) {
            if (vm.isInspectorEnabled()) {
                if (this.strong_this.globalThis) |globalThis| {
                    Debugger.didCancelAsyncCall(globalThis, .DOMTimer, ID.asyncID(.{ .id = id, .kind = kind }));
                }
            }

            this.has_cleared_timer = true;
            this.strong_this.deinit();
            this.deref();

            return .disarm;
        }

        const globalThis = this.strong_this.globalThis.?;
        const this_object = this.strong_this.get().?;
        var time_before_call: timespec = undefined;

        if (kind != .setInterval) {
            this.strong_this.clear();
        } else {
            time_before_call = timespec.msFromNow(this.interval);
        }
        this_object.ensureStillAlive();

        vm.eventLoop().enter();
        {
            // Ensure it stays alive for this scope.
            this.ref();
            defer this.deref();

            run(this_object, globalThis, ID.asyncID(.{ .id = id, .kind = kind }), vm);

            var is_timer_done = false;

            // Node doesn't drain microtasks after each timer callback.
            if (kind == .setInterval) {
                switch (this.eventLoopTimer().state) {
                    .FIRED => {
                        // If we didn't clear the setInterval, reschedule it starting from
                        this.eventLoopTimer().next = time_before_call;
                        vm.timer.insert(this.eventLoopTimer());

                        if (this.has_js_ref) {
                            this.setEnableKeepingEventLoopAlive(vm, true);
                        }

                        // The ref count doesn't change. It wasn't decremented.
                    },
                    .ACTIVE => {
                        // The developer called timer.refresh() synchronously in the callback.
                        vm.timer.remove(this.eventLoopTimer());

                        this.eventLoopTimer().next = time_before_call;
                        vm.timer.insert(this.eventLoopTimer());

                        // Balance out the ref count.
                        // the transition from "FIRED" -> "ACTIVE" caused it to increment.
                        this.deref();
                    },
                    else => {
                        is_timer_done = true;
                    },
                }
            } else if (this.eventLoopTimer().state == .FIRED) {
                is_timer_done = true;
            }

            if (is_timer_done) {
                if (this.is_keeping_event_loop_alive) {
                    this.is_keeping_event_loop_alive = false;

                    switch (this.kind) {
                        .setTimeout, .setInterval => {
                            vm.timer.incrementTimerRef(-1);
                        },
                        else => {},
                    }
                }

                // The timer will not be re-entered into the event loop at this point.
                this.deref();
            }
        }
        vm.eventLoop().exit();

        return .disarm;
    }

    pub fn run(this_object: JSC.JSValue, globalThis: *JSC.JSGlobalObject, async_id: u64, vm: *JSC.VirtualMachine) void {
        if (vm.isInspectorEnabled()) {
            Debugger.willDispatchAsyncCall(globalThis, .DOMTimer, async_id);
        }

        defer {
            if (vm.isInspectorEnabled()) {
                Debugger.didDispatchAsyncCall(globalThis, .DOMTimer, async_id);
            }
        }

        // Bun__JSTimeout__call handles exceptions.
        Bun__JSTimeout__call(this_object, globalThis);
    }

    pub fn init(
        this: *TimerObjectInternals,
        timer_js: JSValue,
        globalThis: *JSGlobalObject,
        id: i32,
        kind: Kind,
        interval: i32,
        callback: JSValue,
        arguments: JSValue,
    ) void {
        this.* = .{
            .id = id,
            .kind = kind,
            .interval = interval,
        };

        if (kind == .setImmediate) {
            if (arguments != .zero)
                ImmediateObject.argumentsSetCached(timer_js, globalThis, arguments);
            ImmediateObject.callbackSetCached(timer_js, globalThis, callback);
        } else {
            if (arguments != .zero)
                TimeoutObject.argumentsSetCached(timer_js, globalThis, arguments);
            TimeoutObject.callbackSetCached(timer_js, globalThis, callback);
            this.reschedule(globalThis.bunVM());
        }

        this.strong_this.set(globalThis, timer_js);
    }

    pub fn doRef(this: *TimerObjectInternals, _: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
        const this_value = callframe.this();
        this_value.ensureStillAlive();

        const did_have_js_ref = this.has_js_ref;
        this.has_js_ref = true;

        if (!did_have_js_ref) {
            this.setEnableKeepingEventLoopAlive(JSC.VirtualMachine.get(), true);
        }

        return this_value;
    }

    pub fn doRefresh(this: *TimerObjectInternals, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
        const this_value = callframe.this();

        // setImmediate does not support refreshing and we do not support refreshing after cleanup
        if (this.id == -1 or this.kind == .setImmediate or this.has_cleared_timer) {
            return this_value;
        }

        this.strong_this.set(globalObject, this_value);
        this.reschedule(VirtualMachine.get());

        return this_value;
    }

    pub fn doUnref(this: *TimerObjectInternals, _: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
        const this_value = callframe.this();
        this_value.ensureStillAlive();

        const did_have_js_ref = this.has_js_ref;
        this.has_js_ref = false;

        if (did_have_js_ref) {
            this.setEnableKeepingEventLoopAlive(JSC.VirtualMachine.get(), false);
        }

        return this_value;
    }

    pub fn cancel(this: *TimerObjectInternals, vm: *VirtualMachine) void {
        this.setEnableKeepingEventLoopAlive(vm, false);
        this.has_cleared_timer = true;

        if (this.kind == .setImmediate) return;

        const was_active = this.eventLoopTimer().state == .ACTIVE;

        this.eventLoopTimer().state = .CANCELLED;
        this.strong_this.deinit();

        if (was_active) {
            vm.timer.remove(this.eventLoopTimer());
            this.deref();
        }
    }

    pub fn reschedule(this: *TimerObjectInternals, vm: *VirtualMachine) void {
        if (this.kind == .setImmediate) return;

        const now = timespec.msFromNow(this.interval);
        const was_active = this.eventLoopTimer().state == .ACTIVE;
        if (was_active) {
            vm.timer.remove(this.eventLoopTimer());
        } else {
            this.ref();
        }

        this.eventLoopTimer().next = now;
        vm.timer.insert(this.eventLoopTimer());
        this.has_cleared_timer = false;

        if (this.has_js_ref) {
            this.setEnableKeepingEventLoopAlive(vm, true);
        }
    }

    fn setEnableKeepingEventLoopAlive(this: *TimerObjectInternals, vm: *VirtualMachine, enable: bool) void {
        if (this.is_keeping_event_loop_alive == enable) {
            return;
        }
        this.is_keeping_event_loop_alive = enable;

        switch (this.kind) {
            .setTimeout, .setInterval => {
                vm.timer.incrementTimerRef(if (enable) 1 else -1);
            },
            else => {},
        }
    }

    pub fn hasRef(this: *TimerObjectInternals, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
        return JSValue.jsBoolean(this.is_keeping_event_loop_alive);
    }
    pub fn toPrimitive(this: *TimerObjectInternals, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
        if (!this.has_accessed_primitive) {
            this.has_accessed_primitive = true;
            const vm = VirtualMachine.get();
            vm.timer.maps.get(this.kind).put(bun.default_allocator, this.id, this.eventLoopTimer()) catch bun.outOfMemory();
        }
        return JSValue.jsNumber(this.id);
    }

    pub fn finalize(this: *TimerObjectInternals) void {
        this.strong_this.deinit();
        this.deref();
    }

    pub fn deinit(this: *TimerObjectInternals) void {
        this.strong_this.deinit();
        const vm = VirtualMachine.get();

        if (this.eventLoopTimer().state == .ACTIVE) {
            vm.timer.remove(this.eventLoopTimer());
        }

        if (this.has_accessed_primitive) {
            const map = vm.timer.maps.get(this.kind);
            if (map.orderedRemove(this.id)) {
                // If this array gets large, let's shrink it down
                // Array keys are i32
                // Values are 1 ptr
                // Therefore, 12 bytes per entry
                // So if you created 21,000 timers and accessed them by ID, you'd be using 252KB
                const allocated_bytes = map.capacity() * @sizeOf(TimeoutMap.Data);
                const used_bytes = map.count() * @sizeOf(TimeoutMap.Data);
                if (allocated_bytes - used_bytes > 256 * 1024) {
                    map.shrinkAndFree(bun.default_allocator, map.count() + 8);
                }
            }
        }

        this.setEnableKeepingEventLoopAlive(vm, false);
        switch (this.kind) {
            .setImmediate => @as(*ImmediateObject, @fieldParentPtr("internals", this)).destroy(),
            .setTimeout, .setInterval => @as(*TimeoutObject, @fieldParentPtr("internals", this)).destroy(),
        }
    }
};

pub const Kind = enum(u32) {
    setTimeout,
    setInterval,
    setImmediate,
};

// this is sized to be the same as one pointer
pub const ID = extern struct {
    id: i32,

    kind: Kind = Kind.setTimeout,

    pub inline fn asyncID(this: ID) u64 {
        return @bitCast(this);
    }

    pub fn repeats(this: ID) bool {
        return this.kind == .setInterval;
    }
};

const assert = bun.assert;
const heap = bun.io.heap;

pub const EventLoopTimer = struct {
    /// The absolute time to fire this timer next.
    next: timespec,

    /// Internal heap fields.
    heap: heap.IntrusiveField(EventLoopTimer) = .{},

    state: State = .PENDING,

    tag: Tag = .TimerCallback,

    pub const Tag = if (Environment.isWindows) enum {
        TimerCallback,
        TimeoutObject,
        ImmediateObject,
        TestRunner,
        StatWatcherScheduler,
        UpgradedDuplex,
        DNSResolver,
        WindowsNamedPipe,
        PostgresSQLConnectionTimeout,
        PostgresSQLConnectionMaxLifetime,

        pub fn Type(comptime T: Tag) type {
            return switch (T) {
                .TimerCallback => TimerCallback,
                .TimeoutObject => TimeoutObject,
                .ImmediateObject => ImmediateObject,
                .TestRunner => JSC.Jest.TestRunner,
                .StatWatcherScheduler => StatWatcherScheduler,
                .UpgradedDuplex => uws.UpgradedDuplex,
                .DNSResolver => DNSResolver,
                .WindowsNamedPipe => uws.WindowsNamedPipe,
                .PostgresSQLConnectionTimeout => JSC.Postgres.PostgresSQLConnection,
                .PostgresSQLConnectionMaxLifetime => JSC.Postgres.PostgresSQLConnection,
            };
        }
    } else enum {
        TimerCallback,
        TimeoutObject,
        ImmediateObject,
        TestRunner,
        StatWatcherScheduler,
        UpgradedDuplex,
        DNSResolver,
        PostgresSQLConnectionTimeout,
        PostgresSQLConnectionMaxLifetime,

        pub fn Type(comptime T: Tag) type {
            return switch (T) {
                .TimerCallback => TimerCallback,
                .TimeoutObject => TimeoutObject,
                .ImmediateObject => ImmediateObject,
                .TestRunner => JSC.Jest.TestRunner,
                .StatWatcherScheduler => StatWatcherScheduler,
                .UpgradedDuplex => uws.UpgradedDuplex,
                .DNSResolver => DNSResolver,
                .PostgresSQLConnectionTimeout => JSC.Postgres.PostgresSQLConnection,
                .PostgresSQLConnectionMaxLifetime => JSC.Postgres.PostgresSQLConnection,
            };
        }
    };

    const TimerCallback = struct {
        callback: *const fn (*TimerCallback) Arm,
        ctx: *anyopaque,
        event_loop_timer: EventLoopTimer,
    };

    pub const State = enum {
        /// The timer is waiting to be enabled.
        PENDING,

        /// The timer is active and will fire at the next time.
        ACTIVE,

        /// The timer has been cancelled and will not fire.
        CANCELLED,

        /// The timer has fired and the callback has been called.
        FIRED,
    };

    /// If self was created by set{Immediate,Timeout,Interval}, get a pointer to the common data
    /// for all those kinds of timers
    fn jsTimerInternals(self: *const EventLoopTimer) ?*const TimerObjectInternals {
        switch (self.tag) {
            inline .TimeoutObject, .ImmediateObject => |tag| {
                const parent: *const tag.Type() = @fieldParentPtr("event_loop_timer", self);
                return &parent.internals;
            },
            else => return null,
        }
    }

    fn less(_: void, a: *const EventLoopTimer, b: *const EventLoopTimer) bool {
        const order = a.next.order(&b.next);
        if (order == .eq) {
            if (a.jsTimerInternals()) |a_internals| {
                if (b.jsTimerInternals()) |b_internals| {
                    return a_internals.id < b_internals.id;
                }
            }

            if (b.tag == .TimeoutObject or b.tag == .ImmediateObject) {
                return false;
            }
        }

        return order == .lt;
    }

    fn ns(self: *const EventLoopTimer) u64 {
        return self.next.ns();
    }

    pub const Arm = union(enum) {
        rearm: timespec,
        disarm,
    };

    pub fn fire(this: *EventLoopTimer, now: *const timespec, vm: *VirtualMachine) Arm {
        switch (this.tag) {
            .PostgresSQLConnectionTimeout => return @as(*JSC.Postgres.PostgresSQLConnection, @alignCast(@fieldParentPtr("timer", this))).onConnectionTimeout(),
            .PostgresSQLConnectionMaxLifetime => return @as(*JSC.Postgres.PostgresSQLConnection, @alignCast(@fieldParentPtr("max_lifetime_timer", this))).onMaxLifetimeTimeout(),
            inline else => |t| {
                var container: *t.Type() = @alignCast(@fieldParentPtr("event_loop_timer", this));
                if (comptime t.Type() == TimeoutObject or t.Type() == ImmediateObject) {
                    return container.internals.fire(now, vm);
                }

                if (comptime t.Type() == StatWatcherScheduler) {
                    return container.timerCallback();
                }
                if (comptime t.Type() == uws.UpgradedDuplex) {
                    return container.onTimeout();
                }
                if (Environment.isWindows) {
                    if (comptime t.Type() == uws.WindowsNamedPipe) {
                        return container.onTimeout();
                    }
                }

                if (comptime t.Type() == JSC.Jest.TestRunner) {
                    container.onTestTimeout(now, vm);
                    return .disarm;
                }

                if (comptime t.Type() == DNSResolver) {
                    return container.checkTimeouts(now, vm);
                }

                return container.callback(container);
            },
        }
    }

    pub fn deinit(_: *EventLoopTimer) void {}
};

const timespec = bun.timespec;
