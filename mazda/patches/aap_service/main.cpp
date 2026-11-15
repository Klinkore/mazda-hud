// SPDX-License-Identifier: AGPL-3.0-or-later
// aap_service patch entry point. Process gating and module startup live here;
// feature implementation belongs in the navi/ and audio/ modules.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#define LOG_TAG "CORE"
#include "log.h"
#include "audio/audio.h"
#include "navi/navi.h"
#include "common/config.h"
#include "common/preload_guard.h"

#include <unistd.h>
#include <sys/stat.h>

namespace {

__attribute__((constructor))
void aap_service_patch_init()
{
    if (!preload_in_aap_service())
        return;

#ifdef FW70_PORT
    // aap_service is reset_board="yes" in sm.conf: a crash here reboots the
    // unit. Share the blmjciaapa shim's kill switches so a crash loop dies
    // out: manual "disabled" file, or >= 2 recorded fatal signals.
    {
        struct stat st;
        if (access("/data_persist/oem-aa-mod/disabled", F_OK) == 0 ||
            (stat("/data_persist/oem-aa-mod/crashes", &st) == 0 && st.st_size >= 2)) {
            LOGW("aap_service shim: kill switch / crash counter set — inert");
            return;
        }
    }
#endif

    libpatch_config::load(reinterpret_cast<const void *>(&aap_service_patch_init));

    LOGD("loading aap_service modules (pid=%d)", (int)getpid());
    preload_install_fatal_handler();

#ifndef FW70_PORT
    if (libpatch_config::aa_audio_low_latency()) {
        aap_service_audio::init();
        aap_service_audio::sem_clockfix_init();
    } else {
        LOGD("aa_audio_low_latency=false -> stock ALSA start threshold; "
             "audio module inert");
    }
#endif  // FW70: audio module uses FW74-only addresses and is not built
    if (libpatch_config::use_protocol_v1_6()) {
        aap_service_navi::init();
    } else {
        LOGD("use_protocol_v1_6=false -> GAL 1.5 (stock); navi module inert");
    }
}

} // namespace
