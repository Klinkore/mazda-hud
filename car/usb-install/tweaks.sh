#!/bin/sh
# oem-aa-mod fw70 port — INSTALL (Android Auto HUD guidance + touch)
# Target: CMU firmware 70.00.100 only.
# Changes:
#   1. /data_persist/oem-aa-mod/libpatch-blmjciaapa.so   (new file)
#   2. /jci/sm/sm.conf                 (+1 line: LD_PRELOAD for jciAAPA)
#   3. /etc/aap_system_attributes.xml  (navigation subscribe + touch_screen)
# Backups: /data_persist/oem-aa-mod/backup/ and USB oem-aa-mod/backup/

MYDIR=$(dirname "$(readlink -f "$0")")
mount -o rw,remount ${MYDIR}
SRC="${MYDIR}/oem-aa-mod"
DST="/data_persist/oem-aa-mod"
LOG="${MYDIR}/install_log.txt"

msg()
{
  killall -q jci-dialog
  /jci/tools/jci-dialog --info --title="oem-aa-mod FW70 install" --text="$*" --no-cancel &
}
log()
{
  echo "$(date +'%D %T') $*" >> "${LOG}"
}
fail()
{
  log "ABORT: $*"
  sync
  msg "INSTALL ABORTED:\n$*\n\nNothing (more) was changed.\nRemove USB drive."
  sleep 15
  killall -q jci-dialog
  exit 1
}

same()
{
  if command -v cmp >/dev/null 2>&1; then cmp -s "$1" "$2"; return $?; fi
  [ "$(md5sum < "$1")" = "$(md5sum < "$2")" ]
}

collect_logs()
{
  OUT="${MYDIR}/oem-aa-mod-logs/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "${OUT}"
  cp /tmp/oem-aa-mod.log "${OUT}/" 2>/dev/null
  ls -la /data_persist/oem-aa-mod/ > "${OUT}/data_persist_ls.txt" 2>&1
  cp -a /data_persist/oem-aa-mod/crashes /data_persist/oem-aa-mod/bootcount "${OUT}/" 2>/dev/null
  grep -A3 'name="jciAAPA"' /jci/sm/sm.conf > "${OUT}/sm_jciAAPA.txt" 2>&1
  cp /etc/aap_system_attributes.xml "${OUT}/" 2>/dev/null
  cp /tmp/smevents.txt "${OUT}/" 2>/dev/null
  cp /tmp/ALLGO_LOG.txt "${OUT}/" 2>/dev/null
  cp /tmp/AAPA_LOG.txt "${OUT}/" 2>/dev/null
  cp -r /tmp/oem-aa-mod-img "${OUT}/" 2>/dev/null
  ls -la /tmp > "${OUT}/tmp_ls.txt" 2>&1
  ps > "${OUT}/ps.txt" 2>&1
  for p in /proc/[0-9]*; do grep -q jciAAPA $p/cmdline 2>/dev/null && { echo "== $p"; grep -i -e aap -e libpatch $p/maps; }; done > "${OUT}/jciAAPA_maps.txt" 2>&1
  { for k in lvds_speed_restriction bus_bcm_speed_restriction; do echo "$k=$(cat /sys/class/nvram/nv-config/keys/$k 2>&1)"; done; ls -l /jci/scripts/set_*speed_restriction* 2>&1; grep -n "Global.AtSpeed" /jci/gui/common/js/Common.js 2>&1; } > "${OUT}/speed_restriction.txt"
  # Optional: capture what the OEM navigation sends to the HUD (90 s).
  # Enabled by a flag file on the USB drive.
  if [ -f "${MYDIR}/navimon.flag" ]
  then
    msg "Recording native navigation -> HUD traffic for 90 s...\nKeep the native navigation route running.\nDo NOT remove the USB drive."
    dbus-monitor --address unix:path=/tmp/dbus_service_socket "path='/com/jci/vbs/navi'" > "${OUT}/dbus_vbs_navi.txt" 2>&1 &
    M1=$!
    dbus-monitor --address unix:path=/tmp/dbus_hmi_socket "interface='com.jci.navi2IHU'" > "${OUT}/dbus_hmi_navi.txt" 2>&1 &
    M2=$!
    sleep 90
    kill $M1 $M2 2>/dev/null
    sync
  fi
  # OEM navigation service binary (once) — to see how native nav feeds the HUD
  [ -f "${MYDIR}/oem-aa-mod-logs/svcjcinavi.so" ] || cp /jci/navi/svcjcinavi.so "${MYDIR}/oem-aa-mod-logs/" 2>/dev/null
  sync
}

# --- Already installed (same library + sm.conf patched)? -> only collect logs ---
if grep -q 'libpatch-blmjciaapa' /jci/sm/sm.conf 2>/dev/null \
   && [ -f "${DST}/libpatch-blmjciaapa.so" ] \
   && same "${SRC}/libpatch-blmjciaapa.so" "${DST}/libpatch-blmjciaapa.so"
then
  if [ ! -f "${DST}/debug" ]
  then
    # Clean (everyday) mode: turn diagnostics back on and reboot.
    msg "oem-aa-mod is in clean mode.\nEnabling diagnostics (logs)...\nThe system will reboot."
    log "=== CLEAN MODE DETECTED: enabling diagnostics ==="
    touch "${DST}/debug"
    mount -o rw,remount /
    if ! grep -q 'env_name="LOG_PREF"' /jci/sm/sm.conf && [ $(grep -c 'name="aap_service"' /jci/sm/sm.conf) -eq 1 ]
    then
      LINES_BEFORE=$(wc -l < /jci/sm/sm.conf)
      cp -a /jci/sm/sm.conf /tmp/sm.conf.new
      sed -i '/name="aap_service"/a\            <environ_var env_name="LOG_PREF" env_value="ALLGO_LOG -m,3 -l4 -f"/>' /tmp/sm.conf.new
      if [ $(wc -l < /tmp/sm.conf.new) -eq $((LINES_BEFORE + 1)) ]
      then
        cp /tmp/sm.conf.new /jci/sm/sm.conf && log "sm.conf: LOG_PREF added for aap_service"
      fi
      rm -f /tmp/sm.conf.new
    fi
    sync
    mount -o ro,remount / 2>/dev/null
    log "=== DIAGNOSTICS ENABLED ==="
    sync
    mount -o ro,remount ${MYDIR} 2>/dev/null
    msg "Diagnostics enabled.\nRemove the USB drive, reproduce the problem,\nthen insert this USB drive again to collect logs.\nRebooting in 10 seconds."
    sleep 10
    killall -q jci-dialog
    reboot &
    exit 0
  fi
  msg "oem-aa-mod is already installed.\nCollecting logs to USB...\n(nothing is changed, no reboot)"
  log "=== ALREADY INSTALLED: collecting logs only ==="
  collect_logs
  log "=== LOGS COLLECTED ==="
  sync
  sleep 2
  sync
  # Flush FAT metadata for sure: no more writes after this point.
  mount -o ro,remount ${MYDIR} 2>/dev/null
  sync
  msg "DONE! Logs saved to USB.\nNothing was changed.\nYou can remove the USB drive."
  sleep 8
  killall -q jci-dialog
  exit 0
fi

log "=== INSTALL START ==="

# --- 0. Checks ---
grep -q '^JCI_SW_VER=.*_70\.00\.100' /jci/version.ini || fail "Firmware is not 70.00.100"
[ -f "${SRC}/libpatch-blmjciaapa.so" ] || fail "libpatch-blmjciaapa.so missing on USB"
[ -f "${SRC}/aap_system_attributes.xml" ] || fail "aap_system_attributes.xml missing on USB"
grep -q 'name="jciAAPA"' /jci/sm/sm.conf || fail "jciAAPA service not found in sm.conf"
[ $(grep -c 'name="jciAAPA"' /jci/sm/sm.conf) -eq 1 ] || fail "jciAAPA found more than once in sm.conf"

msg "Installing oem-aa-mod (FW70)...\nPlease wait."

mount -o rw,remount / || fail "cannot remount / read-write"

# --- 1. Backups (only the first time, so we always keep the stock files) ---
mkdir -p "${DST}/backup" "${SRC}/backup"
if [ ! -f "${DST}/backup/sm.conf" ]
then
  cp -a /jci/sm/sm.conf "${DST}/backup/sm.conf" || fail "backup of sm.conf failed"
  cp -a /etc/aap_system_attributes.xml "${DST}/backup/aap_system_attributes.xml" || fail "backup of xml failed"
  log "Backups created in ${DST}/backup"
else
  log "Backups already exist in ${DST}/backup (kept)"
fi
cp -a "${DST}/backup/sm.conf" "${DST}/backup/aap_system_attributes.xml" "${SRC}/backup/"
sync

# --- 2. Library ---
cp "${SRC}/libpatch-blmjciaapa.so" "${DST}/libpatch-blmjciaapa.so" || fail "copy of library failed"
chmod 0644 "${DST}/libpatch-blmjciaapa.so"
same "${SRC}/libpatch-blmjciaapa.so" "${DST}/libpatch-blmjciaapa.so" || fail "library copy verify failed"
[ -f "${SRC}/libpatch.conf" ] && cp "${SRC}/libpatch.conf" "${DST}/libpatch.conf"
# fresh guard counters + debug log enabled
rm -f "${DST}/crashes" "${DST}/bootcount" "${DST}/disabled"
touch "${DST}/debug"
rm -f "${DST}/hudtest"
sync
log "Library installed"

# --- 3. sm.conf: add LD_PRELOAD to jciAAPA (once) ---
if grep -q 'libpatch-blmjciaapa' /jci/sm/sm.conf
then
  log "sm.conf already patched"
else
  LINES_BEFORE=$(wc -l < /jci/sm/sm.conf)
  cp -a /jci/sm/sm.conf /tmp/sm.conf.new
  sed -i '/name="jciAAPA"/a\            <environ_var env_name="LD_PRELOAD" env_value="/data_persist/oem-aa-mod/libpatch-blmjciaapa.so"/>' /tmp/sm.conf.new
  LINES_AFTER=$(wc -l < /tmp/sm.conf.new)
  N=$(grep -c 'env_value="/data_persist/oem-aa-mod/libpatch-blmjciaapa.so"/>' /tmp/sm.conf.new)
  if [ "$N" -ne 1 ] || [ "$LINES_AFTER" -ne $((LINES_BEFORE + 1)) ]
  then
    rm -f /tmp/sm.conf.new
    fail "sm.conf patch check failed (n=$N, $LINES_BEFORE -> $LINES_AFTER lines)"
  fi
  cp /tmp/sm.conf.new /jci/sm/sm.conf || { cp -a "${DST}/backup/sm.conf" /jci/sm/sm.conf; fail "writing sm.conf failed (restored)"; }
  rm -f /tmp/sm.conf.new
  sync
  log "sm.conf patched:"
  grep -A2 'name="jciAAPA"' /jci/sm/sm.conf >> "${LOG}"
fi

# --- 3b. sm.conf: diagnostic AllGo log for aap_service (once) ---
if grep -q 'env_name="LOG_PREF"' /jci/sm/sm.conf
then
  log "sm.conf: LOG_PREF already present"
elif [ $(grep -c 'name="aap_service"' /jci/sm/sm.conf) -eq 1 ]
then
  LINES_BEFORE=$(wc -l < /jci/sm/sm.conf)
  cp -a /jci/sm/sm.conf /tmp/sm.conf.new
  sed -i '/name="aap_service"/a\            <environ_var env_name="LOG_PREF" env_value="ALLGO_LOG -m,3 -l4 -f"/>' /tmp/sm.conf.new
  LINES_AFTER=$(wc -l < /tmp/sm.conf.new)
  N=$(grep -c 'env_name="LOG_PREF"' /tmp/sm.conf.new)
  if [ "$N" -eq 1 ] && [ "$LINES_AFTER" -eq $((LINES_BEFORE + 1)) ]
  then
    cp /tmp/sm.conf.new /jci/sm/sm.conf && log "sm.conf: LOG_PREF added for aap_service"
  else
    log "sm.conf: LOG_PREF patch check failed — skipped (n=$N)"
  fi
  rm -f /tmp/sm.conf.new
  sync
else
  log "sm.conf: aap_service block not unique — LOG_PREF skipped"
fi

# --- 3c. sm.conf: REMOVE the jciAAPA client log (it logged every touch) ---
if grep -q "AAPA_LOG" /jci/sm/sm.conf
then
  LINES_BEFORE=$(wc -l < /jci/sm/sm.conf)
  cp -a /jci/sm/sm.conf /tmp/sm.conf.new
  sed -i '/AAPA_LOG/d' /tmp/sm.conf.new
  LINES_AFTER=$(wc -l < /tmp/sm.conf.new)
  if [ "$LINES_AFTER" -eq $((LINES_BEFORE - 1)) ] && grep -q 'libpatch-blmjciaapa' /tmp/sm.conf.new
  then
    cp /tmp/sm.conf.new /jci/sm/sm.conf && log "sm.conf: AAPA_LOG removed from jciAAPA"
  else
    log "sm.conf: AAPA_LOG removal check failed — left as is"
  fi
  rm -f /tmp/sm.conf.new
  sync
else
  log "sm.conf: no AAPA_LOG present"
fi

# --- 3d. Touch speed restriction of the LVDS panel (same as AIO/TouchTune) ---
NV=/sys/class/nvram/nv-config/keys
log "nvram before: lvds_speed_restriction=$(cat $NV/lvds_speed_restriction 2>&1) bus_bcm_speed_restriction=$(cat $NV/bus_bcm_speed_restriction 2>&1)"
ls -l /jci/scripts/set_*speed_restriction* >> "${LOG}" 2>&1
if [ -x /jci/scripts/set_lvds_speed_restriction_config.sh ]
then
  if [ "$(cat $NV/lvds_speed_restriction 2>/dev/null)" != "disable" ]
  then
    /jci/scripts/set_lvds_speed_restriction_config.sh disable >> "${LOG}" 2>&1
    log "lvds speed restriction: set to disable"
  else
    log "lvds speed restriction: already disabled"
  fi
else
  log "set_lvds_speed_restriction_config.sh not found — skipped"
fi
log "nvram after: lvds_speed_restriction=$(cat $NV/lvds_speed_restriction 2>&1)"
sync

# --- 4. Android Auto attributes XML ---
cp "${SRC}/aap_system_attributes.xml" /etc/aap_system_attributes.xml || { cp -a "${DST}/backup/aap_system_attributes.xml" /etc/aap_system_attributes.xml; fail "writing xml failed (restored)"; }
chmod 0775 /etc/aap_system_attributes.xml
same "${SRC}/aap_system_attributes.xml" /etc/aap_system_attributes.xml || fail "xml verify failed"
sync
log "aap_system_attributes.xml installed"

mount -o ro,remount / 2>/dev/null
sync
log "=== INSTALL COMPLETE ==="
sync

msg "INSTALL COMPLETE!\n\nRemove the USB drive.\nThe system will reboot in 10 seconds."
sleep 10
killall -q jci-dialog
reboot &
exit 0
