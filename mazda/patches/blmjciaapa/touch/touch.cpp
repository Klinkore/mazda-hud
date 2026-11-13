// evdev type-B multi-touch reader for /dev/input/filtered-touchscreen0.
//
// Started by the aap_create_session shim (lifecycle.cpp) once a
// session is established; stopped before aap_destroy_session. Runs in a
// single dedicated pthread that:
//
//   1. blocks on poll() (so we can exit cleanly on
//      touch_pre_aap_destroy_session() without races on
//      close()-from-another-thread);
//   2. drains a non-blocking read() into struct input_event;
//   3. tracks current slot + tracking_id + position per slot;
//   4. on each SYN_REPORT, builds an MtState snapshot and hands it
//      to touch_on_frame() (touch_send.cpp).
//
// We talk to evdev directly because TUI_OpenReaderTouchScreen (from
// libjcituireader.so) only delivers one finger per callback — its
// TUI_TouchInput_s has no array — so it can't carry multi-touch.

#define LOG_TAG "TOUCH"
#include "../log.h"
#include "touch.h"
#include "touch_send.h"
#include "common/thread_util.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#if !defined(EFD_CLOEXEC)
#  error "eventfd not available in this sysroot"
#endif

namespace {

constexpr char kTouchDevice[] = "/dev/input/filtered-touchscreen0";

// Open-retry policy. The evdev node can be momentarily absent right
// after a session comes up (device re-enumeration, filtered-touch
// daemon still creating the node). On a cold boot it can take well
// over a second to appear, so the old 5-try / 2.5 s ceiling was too
// tight and silently killed touch for the whole session when the node
// was merely slow. This runs on the dedicated reader thread (not a hot
// path), so we can afford a generous ceiling: retry with a fixed
// backoff up to kOpenMaxAttempts before giving up loudly. A bounded
// loop still surfaces a genuinely permanent failure (EACCES, ENODEV)
// instead of spinning on it forever. The stop eventfd interrupts the
// backoff immediately, so the long ceiling never delays shutdown.
constexpr int kOpenRetryDelayMs = 500;
constexpr int kOpenMaxAttempts  = 60;   // ~30 s of retries

pthread_t g_thread;
bool      g_thread_alive = false;

// Stop signal. A single eventfd shared between the lifecycle thread
// (writer) and the reader thread (poller). touch_pre_aap_destroy_session
// writes to it once; that makes it permanently readable, so it
// interrupts BOTH places the reader can block:
//   * the bounded sleep between open() retries, and
//   * the poll() waiting for touch input.
// Using one fd for both lets stop take effect immediately, with no
// timeout-polling latency, and removes the need for a separate atomic
// flag. -1 when no reader is running.
int g_stop_fd = -1;

// True if the stop eventfd has been signalled (non-blocking peek).
bool stop_requested(void)
{
    struct pollfd pfd = { g_stop_fd, POLLIN, 0 };
    return poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN);
}

// Wait up to `ms` for the stop eventfd to be signalled. Returns true
// if stop fired (caller should bail), false if the timeout elapsed.
bool wait_for_stop(int ms)
{
    struct pollfd pfd = { g_stop_fd, POLLIN, 0 };
    int pr = poll(&pfd, 1, ms);
    return pr > 0 && (pfd.revents & POLLIN);
}

// Initialise a brand-new MtState with all slots empty.
void init_state(MtState *s)
{
    for (int i = 0; i < kMaxFingers; ++i) {
        s->fingers[i].tracking_id = -1;
        s->fingers[i].x = 0;
        s->fingers[i].y = 0;
    }
    s->n_active = 0;
}

void recount_active(MtState *s)
{
    int n = 0;
    for (int i = 0; i < kMaxFingers; ++i) {
        if (s->fingers[i].tracking_id >= 0) ++n;
    }
    s->n_active = n;
}

// Open the evdev node, retrying with a bounded backoff until it
// succeeds or a stop is requested. Returns a valid fd, or -1 if we
// were asked to stop before any open succeeded.
int open_touch_device(void)
{
    for (int attempt = 0; attempt < kOpenMaxAttempts; ++attempt) {
        if (stop_requested()) {
            LOGD("touch reader: stop requested before device could be opened");
            return -1;
        }

        int fd = open(kTouchDevice, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd >= 0) {
            if (attempt > 0) {
                LOGD("touch reader: opened %s (fd=%d) after %d retries",
                     kTouchDevice, fd, attempt);
            } else {
                LOGD("touch reader: opened %s (fd=%d)", kTouchDevice, fd);
            }
            return fd;
        }

        if (attempt + 1 >= kOpenMaxAttempts) {
            LOGE("touch reader: open(%s) failed: %s — giving up after "
                 "%d attempts (~%d s)", kTouchDevice, strerror(errno),
                 kOpenMaxAttempts, kOpenMaxAttempts * kOpenRetryDelayMs / 1000);
            break;
        }

        // Log the first failure loudly, then stay quiet so a
        // slow-to-appear node doesn't flood the log while we wait.
        if (attempt == 0) {
            LOGW("touch reader: open(%s) failed: %s — retrying every %d ms "
                 "(up to %d attempts) until the node appears",
                 kTouchDevice, strerror(errno), kOpenRetryDelayMs,
                 kOpenMaxAttempts);
        }

        if (wait_for_stop(kOpenRetryDelayMs)) {
            LOGD("touch reader: stop requested during open backoff");
            return -1;
        }
    }

    return -1;
}

#ifdef FW70_PORT
// ---------------------------------------------------------------------
// fw70: dual-source reader.
//
// /dev/input/filtered-touchscreen0 is produced by the OEM input filter,
// which stops forwarding touches while the car is moving. The raw panel
// ("LVDS TouchScreen", normally event0) has identical capabilities and is
// not speed-filtered. We open both: as soon as the raw node delivers a
// frame we switch to it for the rest of the session; if it never does
// (e.g. it is EVIOCGRAB'ed by the filter daemon) we keep using the
// filtered node exactly as before.
// ---------------------------------------------------------------------
int open_raw_panel(void)
{
    for (int i = 0; i < 10; ++i) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) continue;
        char name[64] = {0};
        if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
            strcmp(name, "LVDS TouchScreen") == 0) {
            LOGD("touch reader: raw panel %s (\"%s\") fd=%d", path, name, fd);
            return fd;
        }
        close(fd);
    }
    LOGW("touch reader: raw panel \"LVDS TouchScreen\" not found");
    return -1;
}

struct SrcState {
    int     fd;
    MtState st;
    int     slot;
    bool    seen_frame;
};

// Apply one evdev event to a source's MT state. Returns true on SYN_REPORT
// (a complete frame is ready), false otherwise. Sets *dropped on SYN_DROPPED.
bool apply_event(SrcState *s, const struct input_event &ev, bool *dropped)
{
    *dropped = false;
    if (ev.type == EV_ABS) {
        switch (ev.code) {
        case ABS_MT_SLOT:
            s->slot = (ev.value >= 0 && ev.value < kMaxFingers) ? ev.value : 0;
            break;
        case ABS_MT_TRACKING_ID:
            s->st.fingers[s->slot].tracking_id = ev.value;
            break;
        case ABS_MT_POSITION_X:
            s->st.fingers[s->slot].x = static_cast<uint32_t>(ev.value);
            break;
        case ABS_MT_POSITION_Y:
            s->st.fingers[s->slot].y = static_cast<uint32_t>(ev.value);
            break;
        default:
            break;
        }
    } else if (ev.type == EV_SYN) {
        if (ev.code == SYN_REPORT) {
            recount_active(&s->st);
            return true;
        }
        if (ev.code == SYN_DROPPED) {
            init_state(&s->st);
            *dropped = true;
            return true;
        }
    }
    return false;
}

void *reader_main(void *)
{
    int fd_f = open_touch_device();          // filtered (always needed)
    if (fd_f < 0) {
        LOGD("touch reader thread exiting (no device)");
        return nullptr;
    }
    int fd_r = open_raw_panel();             // raw (optional)

    SrcState src[2];
    src[0].fd = fd_f; src[1].fd = fd_r;
    for (int k = 0; k < 2; ++k) {
        init_state(&src[k].st);
        src[k].slot = 0;
        src[k].seen_frame = false;
    }
    bool use_raw = false;

    for (;;) {
        struct pollfd pfds[3] = {
            { fd_f,      POLLIN, 0 },
            { g_stop_fd, POLLIN, 0 },
            { fd_r,      POLLIN, 0 },        // fd -1 is ignored by poll()
        };
        int pr = poll(pfds, 3, -1);
        if (pr < 0) {
            if (errno == EINTR) continue;
            LOGE("touch reader: poll() failed: %s", strerror(errno));
            break;
        }
        if (pfds[1].revents & POLLIN) {
            LOGD("touch reader: stop signalled");
            break;
        }

        for (int k = 0; k < 2; ++k) {
            const int pidx = (k == 0) ? 0 : 2;
            if (src[k].fd < 0 || !(pfds[pidx].revents & POLLIN)) continue;

            struct input_event ev;
            ssize_t n = read(src[k].fd, &ev, sizeof(ev));
            if (n != static_cast<ssize_t>(sizeof(ev))) {
                if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                LOGE("touch reader: read error on %s source (%zd, errno=%d) — dropping it",
                     k == 0 ? "filtered" : "raw", n, errno);
                close(src[k].fd);
                src[k].fd = -1;
                if (k == 0) fd_f = -1; else fd_r = -1;
                if (k == 1 && use_raw) {
                    // Raw died mid-session: release fingers, go back to filtered.
                    MtState empty; init_state(&empty);
                    touch_on_frame(empty);
                    use_raw = false;
                }
                continue;
            }

            bool dropped = false;
            if (!apply_event(&src[k], ev, &dropped)) continue;

            if (k == 1 && !use_raw) {
                // First complete raw frame: switch over. If the filtered
                // stream has fingers down, release them first so the phone
                // sees a clean UP before the raw stream takes over.
                if (src[0].st.n_active > 0) {
                    MtState empty; init_state(&empty);
                    touch_on_frame(empty);
                }
                use_raw = true;
                LOGD("touch reader: raw panel delivers events — using it "
                     "(touch works while driving)");
            }

            // Diagnostics: count frames per source; log once per 10 s window
            // that saw activity, so we can tell if a source goes silent while
            // driving.
            {
                static unsigned frames[2] = {0, 0};
                static time_t window = 0;
                ++frames[k];
                time_t now = time(nullptr);
                if (window == 0) window = now;
                if (now - window >= 10) {
                    LOGD("touch stats (10 s): filtered=%u raw=%u using=%s",
                         frames[0], frames[1], use_raw ? "raw" : "filtered");
                    frames[0] = frames[1] = 0;
                    window = now;
                }
            }

            const bool active = (k == 1) == use_raw;
            if (!active) continue;
            if (dropped) LOGW("touch reader: SYN_DROPPED — resetting slot state");
            touch_on_frame(src[k].st);
        }
        if (fd_f < 0 && fd_r < 0) break;
    }

    if (fd_f >= 0) close(fd_f);
    if (fd_r >= 0) close(fd_r);
    LOGD("touch reader thread exiting");
    return nullptr;
}
#else
void *reader_main(void *)
{
    int fd = open_touch_device();
    if (fd < 0) {
        LOGD("touch reader thread exiting (no device)");
        return nullptr;
    }

    MtState cur;
    init_state(&cur);

    int active_slot = 0;

    for (;;) {
        // Poll the touch device and the stop eventfd together. No
        // timeout: stop wakes us instantly via the eventfd instead of
        // a periodic flag re-check.
        struct pollfd pfds[2] = {
            { fd,        POLLIN, 0 },
            { g_stop_fd, POLLIN, 0 },
        };

        int pr = poll(pfds, 2, -1);
        if (pr < 0) {
            if (errno == EINTR) continue;
            LOGE("touch reader: poll() failed: %s", strerror(errno));
            break;
        }
        if (pfds[1].revents & POLLIN) {
            LOGD("touch reader: stop signalled");
            break;
        }
        if (!(pfds[0].revents & POLLIN)) continue;

        struct input_event ev;
        ssize_t n = read(fd, &ev, sizeof(ev));
        if (n != static_cast<ssize_t>(sizeof(ev))) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            LOGE("touch reader: short read (%zd, errno=%d)", n, errno);
            break;
        }

        LOGV("evdev: type=%u code=%u value=%d (slot=%d)",
             ev.type, ev.code, ev.value, active_slot);

        switch (ev.type) {
        case EV_ABS:
            switch (ev.code) {
            case ABS_MT_SLOT:
                if (ev.value >= 0 && ev.value < kMaxFingers) {
                    active_slot = ev.value;
                } else {
                    active_slot = 0;
                }
                break;
            case ABS_MT_TRACKING_ID:
                // ev.value == -1  -> finger released (slot becomes empty)
                // ev.value >= 0   -> new finger landed in this slot
                cur.fingers[active_slot].tracking_id = ev.value;
                break;
            case ABS_MT_POSITION_X:
                cur.fingers[active_slot].x = static_cast<uint32_t>(ev.value);
                break;
            case ABS_MT_POSITION_Y:
                cur.fingers[active_slot].y = static_cast<uint32_t>(ev.value);
                break;
            default:
                break;
            }
            break;

        case EV_SYN:
            if (ev.code == SYN_REPORT) {
                recount_active(&cur);
                LOGV("SYN_REPORT: n_active=%d slot0=(id=%d x=%u y=%u) "
                     "slot1=(id=%d x=%u y=%u)",
                     cur.n_active,
                     cur.fingers[0].tracking_id, cur.fingers[0].x, cur.fingers[0].y,
                     cur.fingers[1].tracking_id, cur.fingers[1].x, cur.fingers[1].y);
                touch_on_frame(cur);
            } else if (ev.code == SYN_MT_REPORT) {
                // Type-A protocol marker — we don't expect it on a
                // type-B device, but accept it as a no-op for safety.
            } else if (ev.code == SYN_DROPPED) {
                // Kernel queue overflowed; the device state we have
                // may be stale. Reset and let the next genuine touch
                // re-establish state. This will emit a synthetic UP
                // path naturally because tracking_ids drop to -1.
                LOGW("touch reader: SYN_DROPPED — resetting slot state");
                init_state(&cur);
                touch_on_frame(cur);
            }
            break;

        default:
            break;
        }
    }

    close(fd);
    LOGD("touch reader thread exiting");
    return nullptr;
}
#endif  // FW70_PORT

} // namespace

void touch_post_aap_create_session(void)
{
    if (g_thread_alive) return;

    // Clear any diff/axis state left over from a previous session so a
    // reconnect starts clean and the reader can re-probe the device.
    touch_send_reset();

    // Create the stop eventfd before the thread so the reader can poll
    // it from the very first open() attempt. EFD_NONBLOCK keeps our
    // stop_requested() peek from ever blocking.
    g_stop_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (g_stop_fd < 0) {
        LOGE("touch reader: eventfd() failed: %s", strerror(errno));
        return;
    }

    // The reader thread opens the evdev node itself (with retries) so
    // that session start stays cheap and a momentarily-absent device
    // doesn't block or break session bring-up.
    int rc = preload_thread_create(&g_thread, reader_main, nullptr);
    if (rc != 0) {
        LOGE("touch reader: pthread_create failed: %d", rc);
        close(g_stop_fd);
        g_stop_fd = -1;
        return;
    }
    g_thread_alive = true;
    LOGD("touch reader: thread started");
}

void touch_pre_aap_destroy_session(void)
{
    if (!g_thread_alive) return;

    // Signal stop: one write makes the eventfd permanently readable,
    // instantly waking the reader whether it's polling for touch input
    // or sleeping between open() retries.
    uint64_t one = 1;
    if (write(g_stop_fd, &one, sizeof(one)) != sizeof(one)) {
        LOGE("touch reader: write(stop eventfd) failed: %s", strerror(errno));
    }

    // Join so there is only ever one reader thread alive at a time:
    // the next session can't start a second reader until this one has
    // fully wound down. With the eventfd wakeup this returns promptly.
    // The reader closes its own touch fd before exiting.
    pthread_join(g_thread, nullptr);
    g_thread_alive = false;

    close(g_stop_fd);
    g_stop_fd = -1;
}
