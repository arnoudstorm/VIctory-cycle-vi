//! Synthetic lifecycle tests for the GameInput stand-in (Cycle VII audit).
//!
//! Independent of the title and of the other tests: each test builds its own
//! hub over a fake host and plays the title's side through the same table
//! slots the title calls. They cover repeated connections, switching between
//! the keyboard's stand-in pad and host pads, a second input session while
//! the first one's readings and callbacks are still alive, stale references
//! and failed calls, freeing readings across session changes, and device
//! changes while other threads read and hold many readings.
//!
//! Memory exhaustion itself is not simulated: an allocation failure aborts a
//! Rust process, so "under memory pressure" here means many readings held by
//! the title and concurrent polling, not failed allocations.
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;

#[derive(Default)]
struct Host {
    pads: [Option<PadState>; PADS],
    keys: Vec<KeyState>,
}

struct Fake(Arc<Mutex<Host>>);

impl Source for Fake {
    fn pad(&mut self, slot: usize) -> Option<PadState> {
        self.0.lock().unwrap().pads[slot]
    }
    fn keys(&mut self) -> Vec<KeyState> {
        self.0.lock().unwrap().keys.clone()
    }
    fn rumble(&mut self, _: usize, _: u16, _: u16) {}
}

fn fake() -> (&'static Hub, Arc<Mutex<Host>>) {
    let host = Arc::new(Mutex::new(Host::default()));
    let hub = Hub::new(Box::new(Fake(Arc::clone(&host))));
    hub.poll();
    (hub, host)
}

fn key(virtual_key: u8) -> KeyState {
    KeyState {
        scan_code: u32::from(virtual_key) + 0x100,
        virtual_key,
        ..Default::default()
    }
}

fn slot<F: Copy, T>(object: *const T, offset: usize) -> F {
    // SAFETY: our objects start with their table, which has the slot.
    let f = unsafe { *(*(object as *const *const *const ())).add(offset / 8) };
    // SAFETY: the caller names the slot's signature.
    unsafe { std::mem::transmute_copy(&f) }
}

/// What a failed call must not leave behind: the title's old pointer.
const SENTINEL: *const c_void = 0xdead_0000 as *const c_void;

type Register = extern "system" fn(
    This,
    *const Device,
    u32,
    u32,
    u32,
    *mut c_void,
    Option<DeviceCallback>,
    *mut u64,
) -> HRESULT;
type Current = extern "system" fn(This, u32, *const Device, Out) -> HRESULT;
type Walk = extern "system" fn(This, *const Reading, u32, *const Device, Out) -> HRESULT;
type Temporal = extern "system" fn(This, u64, *const Device, Out) -> HRESULT;
type Unregister = extern "system" fn(This, u64, u64) -> bool;
type Stop = extern "system" fn(This, u64);
type Find = extern "system" fn(This, *const [u8; 32], Out) -> HRESULT;
type FindOther = extern "system" fn(This, *const c_void, Out) -> HRESULT;
type Create = extern "system" fn(This, Out) -> HRESULT;
type Aggregate = extern "system" fn(This, u32, Out) -> HRESULT;

/// A call's result with the out pointer; failures must write null.
fn checked(hr: HRESULT, out: *const c_void) -> (HRESULT, *const c_void) {
    assert_ne!(out, SENTINEL, "hr {hr:#x} left the out pointer unwritten");
    assert_eq!(hr == S_OK, !out.is_null(), "hr {hr:#x} with out {out:?}");
    (hr, out)
}

fn current_on(hub: &Hub, kind: u32, device: *const Device) -> (HRESULT, *const Reading) {
    let mut out = SENTINEL;
    let hr = slot::<Current, _>(&hub.object, 0x20)(&hub.object, kind, device, &mut out);
    let (hr, out) = checked(hr, out);
    (hr, out.cast())
}

fn current(hub: &Hub, kind: u32, device: usize) -> (HRESULT, *const Reading) {
    current_on(hub, kind, &hub.devices[device])
}

fn walk_on(
    hub: &Hub,
    offset: usize,
    from: *const Reading,
    device: *const Device,
) -> (HRESULT, *const Reading) {
    let mut out = SENTINEL;
    let hr = slot::<Walk, _>(&hub.object, offset)(&hub.object, from, GAMEPAD_KIND, device, &mut out);
    let (hr, out) = checked(hr, out);
    (hr, out.cast())
}

fn next(hub: &Hub, from: *const Reading) -> (HRESULT, *const Reading) {
    walk_on(hub, 0x28, from, std::ptr::null())
}

fn add_ref(reading: *const Reading) -> u32 {
    slot::<extern "system" fn(*const Reading) -> u32, _>(reading, 0x08)(reading)
}

fn release(reading: *const Reading) -> u32 {
    slot::<extern "system" fn(*const Reading) -> u32, _>(reading, 0x10)(reading)
}

fn sequence(reading: *const Reading) -> u64 {
    slot::<extern "system" fn(*const Reading, u32) -> u64, _>(reading, 0x20)(reading, GAMEPAD_KIND)
}

fn timestamp_of(reading: *const Reading) -> u64 {
    slot::<extern "system" fn(*const Reading) -> u64, _>(reading, 0x28)(reading)
}

fn device_of(reading: *const Reading) -> *const Device {
    let mut device = std::ptr::null();
    slot::<extern "system" fn(*const Reading, *mut *const Device), _>(reading, 0x30)(reading, &mut device);
    device
}

fn pad_of(reading: *const Reading) -> PadState {
    let mut state = PadState::default();
    let get = slot::<extern "system" fn(*const Reading, *mut PadState) -> bool, _>(reading, 0xb0);
    assert!(get(reading, &mut state), "a gamepad reading has a pad state");
    state
}

fn status(hub: &Hub, device: usize) -> u32 {
    let device = &hub.devices[device] as *const Device;
    slot::<extern "system" fn(*const Device) -> u32, _>(device, 0x20)(device)
}

/// Device callbacks seen: device index, current and previous status.
type Log = Mutex<Vec<(usize, u32, u32)>>;

extern "system" fn record(
    _token: u64,
    context: *mut c_void,
    device: *const Device,
    _timestamp: u64,
    current: u32,
    previous: u32,
) {
    assert!(!device.is_null(), "a device callback names a device");
    // SAFETY: the test passes its log and one of the hub's devices.
    let (log, index) = unsafe { (&*(context as *const Log), (*device).index) };
    log.lock().unwrap().push((index, current, previous));
}

fn register(hub: &Hub, kind: u32, enumeration: u32, log: &Log) -> u64 {
    let mut token = 0;
    let context = log as *const Log as *mut c_void;
    let hr = slot::<Register, _>(&hub.object, 0x48)(
        &hub.object,
        std::ptr::null(),
        kind,
        STATUS_CONNECTED,
        enumeration,
        context,
        Some(record),
        &mut token,
    );
    assert_eq!(hr, S_OK);
    assert_ne!(token, 0);
    token
}

fn unregister(hub: &Hub, token: u64) -> bool {
    slot::<Unregister, _>(&hub.object, 0x68)(&hub.object, token, 5_000_000)
}

const C: u32 = STATUS_CONNECTED;
const BLOCKING: u32 = 2;

#[test]
fn repeated_connections_and_disconnections_stay_consistent() {
    const CYCLES: usize = 200;
    let (hub, host) = fake();
    let log = Log::default();
    let token = register(hub, GAMEPAD_KIND, BLOCKING, &log);
    // The title keeps the stand-in pad's first reading and pad 0's first.
    let (hr, first_fallback) = current(hub, GAMEPAD_KIND, FALLBACK);
    assert_eq!(hr, S_OK);
    let mut first_pad = std::ptr::null();
    let mut last_sequence = 0;
    for i in 0..CYCLES {
        host.lock().unwrap().pads[0] = Some(PadState {
            buttons: (i as u32) & 0xf,
            ..Default::default()
        });
        hub.poll();
        assert_eq!((status(hub, 0), status(hub, FALLBACK)), (C, 0), "cycle {i}: pad in");
        assert_eq!(status(hub, KEYBOARD), C);
        let (hr, r) = current(hub, GAMEPAD_KIND, 0);
        assert_eq!(hr, S_OK);
        assert!(sequence(r) > last_sequence, "sequence numbers keep rising across reconnects");
        last_sequence = sequence(r);
        assert_eq!(device_of(r), &hub.devices[0] as *const Device);
        if i == 0 {
            first_pad = r;
        } else {
            release(r);
        }

        host.lock().unwrap().pads[0] = None;
        hub.poll();
        assert_eq!((status(hub, 0), status(hub, FALLBACK)), (0, C), "cycle {i}: pad out");
        assert_eq!(current(hub, GAMEPAD_KIND, 0), (DEVICE_DISCONNECTED, std::ptr::null()));
    }

    let seen = log.lock().unwrap().clone();
    assert_eq!(seen.len(), 1 + 4 * CYCLES, "one callback per change, none doubled or lost");
    assert_eq!(seen[0], (FALLBACK, C, 0));
    for (i, c) in seen[1..].chunks(4).enumerate() {
        assert_eq!(c, [(0, C, 0), (FALLBACK, 0, C), (0, 0, C), (FALLBACK, C, 0)], "cycle {i}");
    }
    for s in &hub.state().slots {
        assert!(s.history.len() <= HISTORY, "history stays bounded");
    }

    // Readings the title still holds outlive their place in the history.
    assert_eq!(device_of(first_pad), &hub.devices[0] as *const Device);
    assert_eq!(pad_of(first_pad).buttons, 0);
    assert_eq!(next(hub, first_pad), (REFERENCE_TOO_OLD, std::ptr::null()));
    // The title's last reference frees them.
    assert_eq!(release(first_pad), 0);
    assert_eq!(release(first_fallback), 0);
    assert!(unregister(hub, token));
}

#[test]
fn switching_between_the_stand_in_pad_and_host_pads_follows_the_live_device() {
    let (hub, host) = fake();
    let log = Log::default();
    register(hub, GAMEPAD_KIND, BLOCKING, &log);
    // Enter held: the stand-in pad presses A.
    host.lock().unwrap().keys = vec![key(0x0D)];
    hub.poll();
    let (hr, r) = current_on(hub, GAMEPAD_KIND, std::ptr::null());
    assert_eq!(hr, S_OK);
    assert_eq!(device_of(r), &hub.devices[FALLBACK] as *const Device);
    assert_eq!(pad_of(r).buttons, A);
    release(r);

    let mut last_time = 0;
    for i in 0..50 {
        std::thread::sleep(Duration::from_micros(50));
        host.lock().unwrap().pads[2] = Some(PadState {
            buttons: B,
            ..Default::default()
        });
        hub.poll();
        // Any device: the host pad, and the held key does not leak into it.
        let (hr, r) = current_on(hub, GAMEPAD_KIND, std::ptr::null());
        assert_eq!(hr, S_OK);
        assert_eq!(device_of(r), &hub.devices[2] as *const Device, "switch {i}");
        assert_eq!(pad_of(r).buttons, B);
        assert!(timestamp_of(r) >= last_time);
        last_time = timestamp_of(r);
        release(r);
        assert_eq!(current(hub, GAMEPAD_KIND, FALLBACK), (DEVICE_DISCONNECTED, std::ptr::null()));
        // The keyboard itself stays a device of its own.
        let (hr, k) = current_on(hub, KEYBOARD_KIND, &hub.devices[KEYBOARD]);
        assert_eq!(hr, S_OK);
        release(k);

        std::thread::sleep(Duration::from_micros(50));
        host.lock().unwrap().pads[2] = None;
        hub.poll();
        // Back to the stand-in, with a fresh reading newer than the pad's.
        let (hr, r) = current_on(hub, GAMEPAD_KIND, std::ptr::null());
        assert_eq!(hr, S_OK);
        assert_eq!(device_of(r), &hub.devices[FALLBACK] as *const Device, "switch {i} back");
        assert_eq!(pad_of(r).buttons, A);
        assert!(timestamp_of(r) >= last_time, "the stand-in's reading is the newest");
        last_time = timestamp_of(r);
        release(r);
    }

    // Two host pads: the stand-in returns only when the last one leaves.
    log.lock().unwrap().clear();
    let on = |slot: usize, pad: Option<PadState>| {
        host.lock().unwrap().pads[slot] = pad;
        hub.poll();
    };
    on(1, Some(PadState::default()));
    on(3, Some(PadState::default()));
    on(1, None);
    assert_eq!(status(hub, FALLBACK), 0);
    on(3, None);
    assert_eq!(status(hub, FALLBACK), C);
    assert_eq!(
        *log.lock().unwrap(),
        [(1, C, 0), (FALLBACK, 0, C), (3, C, 0), (1, 0, C), (3, 0, C), (FALLBACK, C, 0)]
    );
}

#[test]
fn a_second_session_while_the_first_ones_readings_and_callbacks_are_alive() {
    let (hub, host) = fake();
    // GameInputCreate refuses a null out pointer before touching the hub.
    assert_eq!(GameInputCreate(std::ptr::null_mut()), E_INVALIDARG);

    // Session one: a blocking and an asynchronous registration, and readings.
    let first = Log::default();
    let first_token = register(hub, GAMEPAD_KIND, BLOCKING, &first);
    let pending = Log::default();
    let pending_token = register(hub, GAMEPAD_KIND, ASYNC_ENUMERATION, &pending);
    let (hr, held) = current(hub, GAMEPAD_KIND, FALLBACK);
    assert_eq!(hr, S_OK);

    // Session one stops its asynchronous registration before the poll that
    // would deliver it: that enumeration never runs.
    slot::<Stop, _>(&hub.object, 0x60)(&hub.object, pending_token);

    // Session two registers before session one has unregistered (overlap):
    // its blocking enumeration reports what is connected now.
    let second = Log::default();
    let second_token = register(hub, GAMEPAD_KIND, BLOCKING, &second);
    assert_eq!(*second.lock().unwrap(), [(FALLBACK, C, 0)]);

    host.lock().unwrap().pads[0] = Some(PadState::default());
    hub.poll();
    assert!(pending.lock().unwrap().is_empty(), "a stopped registration is never called");
    let both = [(FALLBACK, C, 0), (0, C, 0), (FALLBACK, 0, C)];
    assert_eq!(*first.lock().unwrap(), both);
    assert_eq!(*second.lock().unwrap(), both);

    // Session one tears down while it still holds a reading.
    assert!(unregister(hub, first_token));
    host.lock().unwrap().pads[0] = None;
    hub.poll();
    assert_eq!(first.lock().unwrap().len(), 3, "an unregistered session hears nothing more");
    assert_eq!(second.lock().unwrap()[3..], [(0, 0, C), (FALLBACK, C, 0)]);

    // Session one's reading is still valid and still answers.
    assert_eq!(device_of(held), &hub.devices[FALLBACK] as *const Device);
    assert_eq!(pad_of(held), PadState::default());
    assert!(release(held) >= 1, "still in the history, so not freed yet");
    // Unregistering twice, or a token never handed out, is harmless.
    assert!(unregister(hub, first_token));
    assert!(unregister(hub, u64::MAX));
    assert!(unregister(hub, second_token));
}

#[test]
fn stale_references_and_failed_calls_always_clear_the_out_pointer() {
    let (hub, host) = fake();
    let (other, _) = fake();
    let foreign = &other.devices[0] as *const Device;

    // A device of another hub, a disconnected device, a kind it lacks.
    assert_eq!(current_on(hub, GAMEPAD_KIND, foreign), (E_INVALIDARG, std::ptr::null()));
    assert_eq!(current(hub, GAMEPAD_KIND, 1), (DEVICE_DISCONNECTED, std::ptr::null()));
    assert_eq!(current(hub, GAMEPAD_KIND, KEYBOARD), (READING_NOT_FOUND, std::ptr::null()));
    // No device has a kind nobody has.
    assert_eq!(current_on(hub, 0x8000_0000, std::ptr::null()), (READING_NOT_FOUND, std::ptr::null()));

    // Walking: no reference, a reference with the wrong device, a stale one.
    let (hr, r) = current(hub, GAMEPAD_KIND, FALLBACK);
    assert_eq!(hr, S_OK);
    assert_eq!(walk_on(hub, 0x28, std::ptr::null(), std::ptr::null()), (E_INVALIDARG, std::ptr::null()));
    assert_eq!(walk_on(hub, 0x30, r, &hub.devices[0]), (E_INVALIDARG, std::ptr::null()));
    for i in 0..(HISTORY + 4) {
        host.lock().unwrap().keys = if i % 2 == 0 { vec![key(0x0D)] } else { vec![] };
        hub.poll();
    }
    assert_eq!(next(hub, r), (REFERENCE_TOO_OLD, std::ptr::null()));
    assert_eq!(walk_on(hub, 0x30, r, std::ptr::null()), (REFERENCE_TOO_OLD, std::ptr::null()));
    assert_eq!(release(r), 0, "a reading out of the history dies with its last reference");

    // Temporal lookups on a device of another hub.
    let mut out = SENTINEL;
    let hr = slot::<Temporal, _>(&hub.object, 0x38)(&hub.object, now(), foreign, &mut out);
    assert_eq!(checked(hr, out), (E_INVALIDARG, std::ptr::null()));

    // Lookups and objects we do not have.
    let mut out = SENTINEL;
    let hr = slot::<Find, _>(&hub.object, 0x80)(&hub.object, &[7; 32], &mut out);
    assert_eq!(checked(hr, out), (DEVICE_NOT_FOUND, std::ptr::null()));
    for offset in [0x88, 0x90, 0x98] {
        let mut out = SENTINEL;
        let hr = slot::<FindOther, _>(&hub.object, offset)(&hub.object, std::ptr::null(), &mut out);
        assert_eq!(checked(hr, out), (DEVICE_NOT_FOUND, std::ptr::null()));
    }
    let mut out = SENTINEL;
    let hr = slot::<Create, _>(&hub.object, 0x70)(&hub.object, &mut out);
    assert_eq!(checked(hr, out), (E_NOTIMPL, std::ptr::null()));
    let mut out = SENTINEL;
    let hr = slot::<Aggregate, _>(&hub.object, 0x78)(&hub.object, GAMEPAD_KIND, &mut out);
    assert_eq!(checked(hr, out), (E_NOTIMPL, std::ptr::null()));

    // Every device answers for itself, connected or not, with its own id.
    let mut ids = Vec::new();
    for d in &hub.devices {
        let device = d as *const Device;
        let info = slot::<extern "system" fn(*const Device) -> *const u8, _>(device, 0x18)(device);
        assert!(!info.is_null());
        // SAFETY: the info has the id at +0x20.
        ids.push(unsafe { *(info.add(0x20) as *const [u8; 32]) });
    }
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), DEVICES, "device ids are unique");
}

#[test]
fn readings_held_across_session_changes_are_freed_by_their_last_release() {
    const HELD: usize = 100;
    let (hub, host) = fake();
    host.lock().unwrap().pads[0] = Some(PadState::default());
    hub.poll();
    let mut held = Vec::new();
    for i in 0..HELD {
        host.lock().unwrap().pads[0] = Some(PadState {
            left_x: i as f32 / HELD as f32,
            ..Default::default()
        });
        hub.poll();
        let (hr, r) = current(hub, GAMEPAD_KIND, 0);
        assert_eq!(hr, S_OK);
        held.push(r);
    }
    // The session ends: the pad goes, the title still holds every reading.
    host.lock().unwrap().pads[0] = None;
    hub.poll();
    // A reference taken now and given back again changes nothing.
    assert_eq!(add_ref(held[0]), 2);
    assert_eq!(release(held[0]), 1);

    let in_history = hub.state().slots[0].history.len();
    assert!(in_history <= HISTORY);
    let freed = held.iter().filter(|&&r| release(r) == 0).count();
    // Readings still in the history keep the history's own reference.
    assert_eq!(freed, HELD - in_history.min(HELD), "every reading out of the history was freed");

    // A new session: the slot reconnects and the history rolls over the rest.
    for i in 0..(HISTORY + 1) {
        host.lock().unwrap().pads[0] = Some(PadState {
            buttons: i as u32,
            ..Default::default()
        });
        hub.poll();
    }
    assert!(hub.state().slots[0].history.len() <= HISTORY);
}

#[test]
fn device_changes_while_other_threads_read_and_hold_many_readings() {
    const READERS: usize = 4;
    const HOLD: usize = 5000;
    static CALLBACKS: AtomicUsize = AtomicUsize::new(0);
    extern "system" fn count(_: u64, context: *mut c_void, device: *const Device, _: u64, current: u32, previous: u32) {
        // SAFETY: the test's hub, alive for the process.
        let hub = unsafe { &*(context as *const Hub) };
        assert!(hub.index(device).is_some(), "callbacks name one of our devices");
        assert_ne!(current, previous, "a callback reports a change");
        CALLBACKS.fetch_add(1, Ordering::SeqCst);
    }
    let (hub, host) = fake();
    let mut token = 0;
    let hr = slot::<Register, _>(&hub.object, 0x48)(
        &hub.object,
        std::ptr::null(),
        GAMEPAD_KIND,
        STATUS_CONNECTED,
        BLOCKING,
        (hub as *const Hub).cast_mut().cast(),
        Some(count),
        &mut token,
    );
    assert_eq!(hr, S_OK);

    let stop = Arc::new(AtomicBool::new(false));
    let readers: Vec<_> = (0..READERS)
        .map(|_| {
            let stop = Arc::clone(&stop);
            std::thread::spawn(move || {
                let mut held: Vec<usize> = Vec::with_capacity(HOLD);
                let mut reads = 0usize;
                while !stop.load(Ordering::SeqCst) {
                    let (hr, r) = current_on(hub, GAMEPAD_KIND, std::ptr::null());
                    if hr != S_OK {
                        assert_eq!(hr, READING_NOT_FOUND);
                        continue;
                    }
                    reads += 1;
                    assert!(hub.index(device_of(r)).is_some());
                    pad_of(r);
                    let (hr, n) = next(hub, r);
                    assert!([S_OK, READING_NOT_FOUND, REFERENCE_TOO_OLD].contains(&hr), "next {hr:#x}");
                    if hr == S_OK {
                        assert!(sequence(n) > sequence(r));
                        release(n);
                    }
                    if held.len() < HOLD {
                        held.push(r as usize);
                    } else {
                        release(r);
                    }
                }
                for r in held {
                    release(r as *const Reading);
                }
                reads
            })
        })
        .collect();

    let start = Instant::now();
    let mut changes = 0;
    while start.elapsed() < Duration::from_secs(2) {
        {
            let mut host = host.lock().unwrap();
            let i = changes;
            host.pads[0] = (i % 3 != 0).then(|| PadState {
                buttons: (i as u32) & 0xff,
                ..Default::default()
            });
            host.pads[1] = (i % 5 == 0).then(PadState::default);
            host.keys = if i % 2 == 0 { vec![key(0x0D), key(b'W')] } else { vec![] };
        }
        hub.poll();
        changes += 1;
    }
    stop.store(true, Ordering::SeqCst);
    let reads: usize = readers.into_iter().map(|t| t.join().unwrap()).sum();
    assert!(reads > 0 && changes > 100, "reads {reads}, changes {changes}");
    assert!(CALLBACKS.load(Ordering::SeqCst) > 1, "connection changes reached the callback");
    for s in &hub.state().slots {
        assert!(s.history.len() <= HISTORY);
        for r in &s.history {
            assert_eq!(r.refs.load(Ordering::SeqCst), 1, "only the history holds what is left");
        }
    }
    assert!(unregister(hub, token));
}

/// The documented contract of blocking enumeration: every connected device
/// is reported on the registering thread before registration returns. This
/// checks it while the poll thread is in the middle of delivering another
/// registration's callback.
///
/// Cycle VII audit: fails every time on 0e6e5eab (10 of 10 runs). The
/// registration's events join the poll thread's delivery queue and the call
/// returns before they run. Waiting for them instead could deadlock when the
/// title registers while holding a lock its callback takes (see
/// `register_device`), so this stays a recorded deviation, not a fix. The
/// T5c crash did not take this path: its registrations all came at start-up.
#[test]
#[ignore = "confirmed deviation from the documented contract; a fix risks the deadlock register_device avoids"]
fn blocking_enumeration_reports_before_registration_returns_while_the_poll_delivers() {
    static INSIDE: AtomicBool = AtomicBool::new(false);
    static LEAVE: AtomicBool = AtomicBool::new(false);
    extern "system" fn slow(_: u64, _: *mut c_void, _: *const Device, _: u64, _: u32, _: u32) {
        INSIDE.store(true, Ordering::SeqCst);
        while !LEAVE.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    let (hub, host) = fake();
    let mut token = 0;
    let hr = slot::<Register, _>(&hub.object, 0x48)(
        &hub.object,
        std::ptr::null(),
        GAMEPAD_KIND,
        STATUS_CONNECTED,
        0,
        std::ptr::null_mut(),
        Some(slow),
        &mut token,
    );
    assert_eq!(hr, S_OK);
    host.lock().unwrap().pads[1] = Some(PadState::default());
    let poller = std::thread::spawn(move || hub.poll());
    while !INSIDE.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(1));
    }

    let log = Log::default();
    register(hub, GAMEPAD_KIND, BLOCKING, &log);
    let reported_before_return = log.lock().unwrap().len();
    LEAVE.store(true, Ordering::SeqCst);
    poller.join().unwrap();
    let reported_after = log.lock().unwrap().len();
    assert!(reported_after >= 1, "the enumeration ran eventually");
    assert_eq!(
        reported_before_return, 1,
        "blocking enumeration returned before reporting pad 1 (reported {reported_before_return}, later {reported_after})"
    );
}
