// Shared logging helper used across all patches.
//
// Define LOG_TAG (subsystem) and LIBPATCH_NAME (the libpatch-<name>
// the messages should be tagged with) before including this header.
// Each patch supplies a thin local log.h that sets LIBPATCH_NAME and
// includes this file, so per-TU includes stay `#include "../log.h"`.
//
// Coarse log helpers. The launcher PID's stderr is captured by sm
// into the device log. Each message carries the library name, the
// subsystem tag, and a level letter, so they're easy to grep:
//
//   [libpatch-blmjciaapa][TOUCH][V]  verbose
//   [libpatch-svcjcinavi][MERGE][D]  debug
//
// Levels are compile-time-gated by LOG_LEVEL: anything below the
// threshold expands to an `if (false)` guard so the format string is
// still type-checked but never executed. The Makefile passes -DDEBUG
// for debug and -DNDEBUG for release; we key off those (debug =>
// VERBOSE, release => ERROR).

#ifndef LIBPATCH_COMMON_LOG_H
#define LIBPATCH_COMMON_LOG_H

#include <stdint.h>
#include <cstdio>

// Library name woven into every line. A patch's local log.h defines
// this before including; fall back to a neutral label otherwise.
#ifndef LIBPATCH_NAME
#  define LIBPATCH_NAME "patch"
#endif

#define LOG_LEVEL_VERBOSE  0
#define LOG_LEVEL_DEBUG    1
#define LOG_LEVEL_WARN     2
#define LOG_LEVEL_ERROR    3
#define LOG_LEVEL_CRITICAL 4
#define LOG_LEVEL_SILENT   5

#ifndef LOG_LEVEL
#  ifdef NDEBUG
#    define LOG_LEVEL LOG_LEVEL_ERROR
#  else
#    define LOG_LEVEL LOG_LEVEL_VERBOSE
#  endif
#endif

// Subsystem tag for this translation unit. Define before including
// to override; defaults to "CORE" for loader / lifecycle TUs.
#ifndef LOG_TAG
#  define LOG_TAG "CORE"
#endif

// fw70 port: besides stderr, mirror log lines into /tmp/oem-aa-mod.log
// (tmpfs, wiped on reboot) when the flag file
// /data_persist/oem-aa-mod/debug exists. Hard-capped at 2 MB so it can
// never fill /tmp; after the cap further lines are silently dropped.
#include <unistd.h>
#include <ctime>
inline std::FILE *libpatch_logfile(void)
{
    static int state = 0;          // 0 = unchecked, 1 = open, 2 = disabled
    static std::FILE *f = nullptr;
    if (state == 0) {
        state = 2;
        if (access("/data_persist/oem-aa-mod/debug", F_OK) == 0) {
            f = std::fopen("/tmp/oem-aa-mod.log", "a");
            if (f) state = 1;
        }
    }
    if (state != 1) return nullptr;
    if (std::ftell(f) > 2L * 1024 * 1024) { state = 2; return nullptr; }
    return f;
}

#define LOG_EMIT(tag, fmt, ...)                                                \
    do {                                                                       \
        std::fprintf(stderr,                                                   \
                     "[libpatch-" LIBPATCH_NAME "][" LOG_TAG "][" tag "] " fmt "\n", \
                     ##__VA_ARGS__);                                           \
        std::fflush(stderr);                                                   \
        std::FILE *lf_ = libpatch_logfile();                                   \
        if (lf_) {                                                             \
            std::fprintf(lf_, "%ld [" LIBPATCH_NAME "][" LOG_TAG "][" tag "] " fmt "\n", \
                         (long)time(nullptr), ##__VA_ARGS__);                  \
            std::fflush(lf_);                                                  \
        }                                                                      \
    } while (0)

// Keep the format string type-checked even when the level is
// compiled out. `if (false)` is folded by the compiler at all
// optimisation levels, so neither the fprintf nor the argument
// expressions are evaluated at runtime.
#define LOG_DROP(fmt, ...)                                                     \
    do {                                                                       \
        if (false) {                                                           \
            std::fprintf(stderr,                                               \
                         "[libpatch-" LIBPATCH_NAME "][" LOG_TAG "] " fmt "\n", \
                         ##__VA_ARGS__);                                       \
        }                                                                      \
    } while (0)

#if LOG_LEVEL <= LOG_LEVEL_VERBOSE
#  define LOGV(fmt, ...) LOG_EMIT("V", fmt, ##__VA_ARGS__)
#else
#  define LOGV(fmt, ...) LOG_DROP(fmt, ##__VA_ARGS__)
#endif

#if LOG_LEVEL <= LOG_LEVEL_DEBUG
#  define LOGD(fmt, ...) LOG_EMIT("D", fmt, ##__VA_ARGS__)
#else
#  define LOGD(fmt, ...) LOG_DROP(fmt, ##__VA_ARGS__)
#endif

#if LOG_LEVEL <= LOG_LEVEL_WARN
#  define LOGW(fmt, ...) LOG_EMIT("W", fmt, ##__VA_ARGS__)
#else
#  define LOGW(fmt, ...) LOG_DROP(fmt, ##__VA_ARGS__)
#endif

#if LOG_LEVEL <= LOG_LEVEL_ERROR
#  define LOGE(fmt, ...) LOG_EMIT("E", fmt, ##__VA_ARGS__)
#else
#  define LOGE(fmt, ...) LOG_DROP(fmt, ##__VA_ARGS__)
#endif

#if LOG_LEVEL <= LOG_LEVEL_CRITICAL
#  define LOGC(fmt, ...) LOG_EMIT("C", fmt, ##__VA_ARGS__)
#else
#  define LOGC(fmt, ...) LOG_DROP(fmt, ##__VA_ARGS__)
#endif

#endif // LIBPATCH_COMMON_LOG_H
