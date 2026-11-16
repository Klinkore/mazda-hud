#!/bin/sh
# oem-aa-mod fw70 port — USB MENU (choose on the head-unit screen)
# Target: CMU firmware 70.00.100 only.
#
#   [GAL 1.6] install HUD/touch mod + GAL 1.6 (aap_service shim, gal16 flag)
#   [Test 10] install HUD/touch mod, GAL 1.6 OFF (removes aap_service shim)
#   [Logs]    collect logs to USB, change nothing
#
# Changes (install modes):
#   /data_persist/oem-aa-mod/libpatch-blmjciaapa.so (+ libpatch-aap_service.so, gal16 for 1.6)
#   /jci/sm/sm.conf  LD_PRELOAD for jciAAPA (+ aap_service for 1.6), LOG_PREF for aap_service
#   /etc/aap_system_attributes.xml
# Backups of the stock files: /data_persist/oem-aa-mod/backup/ and USB oem-aa-mod/backup/

MYDIR=$(dirname "$(readlink -f "$0")")
mount -o rw,remount ${MYDIR}
SRC="${MYDIR}/oem-aa-mod"
DST="/data_persist/oem-aa-mod"
LOG="${MYDIR}/install_log.txt"
AAP_PRELOAD='<environ_var env_name="LD_PRELOAD" env_value="/data_persist/oem-aa-mod/libpatch-aap_service.so"/>'

msg()
{
  killall -q jci-dialog
  /jci/tools/jci-dialog --info --title="oem-aa-mod FW70" --text="$*" --no-cancel &
}
log()
{
  echo "$(date +'%D %T') $*" >> "${LOG}"
}
fail()
{
  log "ABORT: $*"
  sync
  msg "ABORTED:\n$*\n\nNothing (more) was changed.\nRemove USB drive."
  sleep 15
  killall -q jci-dialog
  exit 1
}
same()
{
  if command -v cmp >/dev/null 2>&1; then cmp -s "$1" "$2"; return $?; fi
  [ "$(md5sum < "$1")" = "$(md5sum < "$2")" ]
}

# Apply a sed edit to sm.conf only if the line count changes by exactly $2
# and the result still contains $3. Usage: smconf_edit '<sed script>' <delta> <must-contain> <label>
smconf_edit()
{
  LINES_BEFORE=$(wc -l < /jci/sm/sm.conf)
  cp -a /jci/sm/sm.conf /tmp/sm.conf.new
  sed -i "$1" /tmp/sm.conf.new
  LINES_AFTER=$(wc -l < /tmp/sm.conf.new)
  if [ "$LINES_AFTER" -eq $((LINES_BEFORE + $2)) ] && grep -q "$3" /tmp/sm.conf.new
  then
    cp /tmp/sm.conf.new /jci/sm/sm.conf || { cp -a "${DST}/backup/sm.conf" /jci/sm/sm.conf; rm -f /tmp/sm.conf.new; fail "writing sm.conf failed (restored): $4"; }
    log "sm.conf: $4"
  else
    log "sm.conf: $4 — check failed ($LINES_BEFORE -> $LINES_AFTER lines), skipped"
    rm -f /tmp/sm.conf.new
    return 1
  fi
  rm -f /tmp/sm.conf.new
  sync
  return 0
}

collect_logs()
{
  OUT="${MYDIR}/oem-aa-mod-logs/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "${OUT}"
  cp /tmp/oem-aa-mod.log "${OUT}/" 2>/dev/null
  ls -la /data_persist/oem-aa-mod/ > "${OUT}/data_persist_ls.txt" 2>&1
  cp -a /data_persist/oem-aa-mod/crashes /data_persist/oem-aa-mod/bootcount "${OUT}/" 2>/dev/null
  grep -A3 -e 'name="jciAAPA"' -e 'name="aap_service"' /jci/sm/sm.conf > "${OUT}/sm_jciAAPA.txt" 2>&1
  cp /etc/aap_system_attributes.xml "${OUT}/" 2>/dev/null
  cp /tmp/smevents.txt "${OUT}/" 2>/dev/null
  cp /tmp/ALLGO_LOG.txt "${OUT}/" 2>/dev/null
  ls -la /tmp > "${OUT}/tmp_ls.txt" 2>&1
  ps > "${OUT}/ps.txt" 2>&1
  for p in /proc/[0-9]*; do grep -q -e jciAAPA -e aap_service $p/cmdline 2>/dev/null && { echo "== $p $(tr '\0' ' ' < $p/cmdline)"; grep -i -e libpatch $p/maps; }; done > "${OUT}/preload_maps.txt" 2>&1
  { for k in lvds_speed_restriction bus_bcm_speed_restriction; do echo "$k=$(cat /sys/class/nvram/nv-config/keys/$k 2>&1)"; done; } > "${OUT}/speed_restriction.txt"
  sync
}

do_logs()
{
  msg "Collecting logs to USB...\n(nothing is changed, no reboot)"
  log "=== LOGS ==="
  collect_logs
  log "=== LOGS COLLECTED ==="
  sync
  sleep 2
  sync
  mount -o ro,remount ${MYDIR} 2>/dev/null
  sync
  msg "DONE! Logs saved to USB.\nNothing was changed.\nYou can remove the USB drive."
  sleep 8
  killall -q jci-dialog
  exit 0
}

# $1 = gal16 | test10
do_install()
{
  MODE="$1"
  log "=== INSTALL START (mode=${MODE}) ==="

  grep -q '^JCI_SW_VER=.*_70\.00\.100' /jci/version.ini || fail "Firmware is not 70.00.100"
  [ -f "${SRC}/libpatch-blmjciaapa.so" ] || fail "libpatch-blmjciaapa.so missing on USB"
  [ -f "${SRC}/aap_system_attributes.xml" ] || fail "aap_system_attributes.xml missing on USB"
  [ "${MODE}" != "gal16" ] || [ -f "${SRC}/libpatch-aap_service.so" ] || fail "libpatch-aap_service.so missing on USB"
  [ $(grep -c 'name="jciAAPA"' /jci/sm/sm.conf) -eq 1 ] || fail "jciAAPA not found exactly once in sm.conf"
  [ $(grep -c 'name="aap_service"' /jci/sm/sm.conf) -eq 1 ] || fail "aap_service not found exactly once in sm.conf"

  msg "Installing oem-aa-mod (${MODE})...\nPlease wait."
  mount -o rw,remount / || fail "cannot remount / read-write"

  # --- 1. Backups of the stock files (first time only) ---
  mkdir -p "${DST}/backup" "${SRC}/backup"
  if [ ! -f "${DST}/backup/sm.conf" ]
  then
    cp -a /jci/sm/sm.conf "${DST}/backup/sm.conf" || fail "backup of sm.conf failed"
    cp -a /etc/aap_system_attributes.xml "${DST}/backup/aap_system_attributes.xml" || fail "backup of xml failed"
    log "Backups created in ${DST}/backup"
  fi
  cp -a "${DST}/backup/sm.conf" "${DST}/backup/aap_system_attributes.xml" "${SRC}/backup/" 2>/dev/null
  sync

  # --- 2. Libraries + flags ---
  cp "${SRC}/libpatch-blmjciaapa.so" "${DST}/libpatch-blmjciaapa.so" || fail "copy of library failed"
  chmod 0644 "${DST}/libpatch-blmjciaapa.so"
  same "${SRC}/libpatch-blmjciaapa.so" "${DST}/libpatch-blmjciaapa.so" || fail "library copy verify failed"
  rm -f "${DST}/crashes" "${DST}/bootcount" "${DST}/disabled" "${DST}/hudtest"
  touch "${DST}/debug"
  if [ "${MODE}" = "gal16" ]
  then
    cp "${SRC}/libpatch-aap_service.so" "${DST}/libpatch-aap_service.so" || fail "copy of aap_service shim failed"
    chmod 0644 "${DST}/libpatch-aap_service.so"
    same "${SRC}/libpatch-aap_service.so" "${DST}/libpatch-aap_service.so" || fail "aap_service shim verify failed"
    touch "${DST}/gal16"
    if [ -f "${SRC}/btaddr" ]; then cp "${SRC}/btaddr" "${DST}/btaddr" && log "btaddr installed"; else rm -f "${DST}/btaddr"; log "no btaddr on USB"; fi
    log "GAL 1.6: shim installed, gal16 flag set"
  else
    rm -f "${DST}/gal16"
    log "GAL 1.6: flag removed"
  fi
  sync

  # --- 3. sm.conf ---
  # 3a. jciAAPA preload (once)
  if ! grep -q 'libpatch-blmjciaapa' /jci/sm/sm.conf
  then
    smconf_edit '/name="jciAAPA"/a\            <environ_var env_name="LD_PRELOAD" env_value="/data_persist/oem-aa-mod/libpatch-blmjciaapa.so"/>' 1 'libpatch-blmjciaapa' "LD_PRELOAD added for jciAAPA" \
      || fail "sm.conf patch for jciAAPA failed"
  fi
  # 3b. AllGo log for aap_service (once)
  grep -q 'env_name="LOG_PREF"' /jci/sm/sm.conf || \
    smconf_edit '/name="aap_service"/a\            <environ_var env_name="LOG_PREF" env_value="ALLGO_LOG -m,3 -l4 -f"/>' 1 'env_name="LOG_PREF"' "LOG_PREF added for aap_service"
  # 3c. drop the old jciAAPA client log if present
  grep -q "AAPA_LOG" /jci/sm/sm.conf && smconf_edit '/AAPA_LOG/d' -1 'libpatch-blmjciaapa' "AAPA_LOG removed"
  # 3d. aap_service preload: add for 1.6, remove otherwise
  if [ "${MODE}" = "gal16" ]
  then
    grep -q 'libpatch-aap_service' /jci/sm/sm.conf || \
      smconf_edit "/name=\"aap_service\"/a\\            ${AAP_PRELOAD}" 1 'libpatch-aap_service' "LD_PRELOAD added for aap_service" \
      || fail "sm.conf patch for aap_service failed"
  else
    grep -q 'libpatch-aap_service' /jci/sm/sm.conf && \
      smconf_edit '/libpatch-aap_service/d' -1 'libpatch-blmjciaapa' "LD_PRELOAD removed from aap_service"
    grep -q 'libpatch-aap_service' /jci/sm/sm.conf && fail "could not remove aap_service preload"
  fi
  grep -A3 -e 'name="jciAAPA"' -e 'name="aap_service"' /jci/sm/sm.conf >> "${LOG}"

  # --- 4. Touch at speed (LVDS restriction off, same as AIO/TouchTune) ---
  NV=/sys/class/nvram/nv-config/keys
  if [ -x /jci/scripts/set_lvds_speed_restriction_config.sh ] && [ "$(cat $NV/lvds_speed_restriction 2>/dev/null)" != "disable" ]
  then
    /jci/scripts/set_lvds_speed_restriction_config.sh disable >> "${LOG}" 2>&1
    log "lvds speed restriction: set to disable"
  fi

  # --- 5. Android Auto attributes XML ---
  cp "${SRC}/aap_system_attributes.xml" /etc/aap_system_attributes.xml || { cp -a "${DST}/backup/aap_system_attributes.xml" /etc/aap_system_attributes.xml; fail "writing xml failed (restored)"; }
  chmod 0775 /etc/aap_system_attributes.xml
  same "${SRC}/aap_system_attributes.xml" /etc/aap_system_attributes.xml || fail "xml verify failed"

  sync
  mount -o ro,remount / 2>/dev/null
  log "=== INSTALL COMPLETE (mode=${MODE}) ==="
  sync
  mount -o ro,remount ${MYDIR} 2>/dev/null
  sync
  msg "INSTALL COMPLETE (${MODE})!\n\nRemove the USB drive.\nThe system will reboot in 10 seconds."
  sleep 10
  killall -q jci-dialog
  reboot &
  exit 0
}

# --- Menu ---
CUR="Test 10 (GAL 1.6 off)"
[ -f "${DST}/gal16" ] && grep -q 'libpatch-aap_service' /jci/sm/sm.conf 2>/dev/null && CUR="GAL 1.6"
grep -q 'libpatch-blmjciaapa' /jci/sm/sm.conf 2>/dev/null || CUR="not installed"

killall -q jci-dialog
/jci/tools/jci-dialog --3-button-dialog \
  --title="oem-aa-mod FW70" \
  --text="Installed now: ${CUR}\n\nGAL 1.6 - install with GAL 1.6\nTest 10 - install without GAL 1.6\nLogs - collect logs, change nothing" \
  --ok-label="GAL 1.6" \
  --cancel-label="Test 10" \
  --button3-label="Logs"
CHOICE=$?
log "menu: choice=${CHOICE} (installed: ${CUR})"

case "${CHOICE}" in
  0) do_install gal16 ;;
  1) do_install test10 ;;
  *) do_logs ;;
esac
