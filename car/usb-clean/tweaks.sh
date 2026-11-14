#!/bin/sh
# oem-aa-mod fw70 port — switch to CLEAN (everyday) mode.
# Keeps the mod installed (touch + HUD guidance), but turns off diagnostics:
#   - removes flags /data_persist/oem-aa-mod/debug and /hudtest
#     (no shim log, no HUD self-test on every Android Auto start)
#   - removes the aap_service LOG_PREF (AllGo log) line from sm.conf
# Nothing else is changed. Reboots at the end.

MYDIR=$(dirname "$(readlink -f "$0")")
mount -o rw,remount ${MYDIR}
DST="/data_persist/oem-aa-mod"
LOG="${MYDIR}/clean_log.txt"

msg()
{
  killall -q jci-dialog
  /jci/tools/jci-dialog --info --title="oem-aa-mod FW70: clean mode" --text="$*" --no-cancel &
}
log()
{
  echo "$(date +'%D %T') $*" >> "${LOG}"
}

log "=== CLEAN MODE START ==="

if ! grep -q 'libpatch-blmjciaapa' /jci/sm/sm.conf || [ ! -f "${DST}/libpatch-blmjciaapa.so" ]
then
  log "mod is not installed — nothing to do"
  sync
  msg "oem-aa-mod is not installed.\nNothing was changed.\nRemove the USB drive."
  sleep 10
  killall -q jci-dialog
  exit 0
fi

msg "Switching oem-aa-mod to clean mode...\nPlease wait."

# 1. Diagnostic flags off
rm -f "${DST}/debug" "${DST}/hudtest" "${DST}/rawtouch"
sync
log "flags removed; now: $(ls ${DST} | tr '\n' ' ')"

# 2. Remove AllGo LOG_PREF from sm.conf (keeps LD_PRELOAD for jciAAPA)
mount -o rw,remount /
if grep -q 'env_name="LOG_PREF"' /jci/sm/sm.conf
then
  N_BEFORE=$(grep -c 'env_name="LOG_PREF"' /jci/sm/sm.conf)
  LINES_BEFORE=$(wc -l < /jci/sm/sm.conf)
  cp -a /jci/sm/sm.conf /tmp/sm.conf.new
  sed -i '/env_name="LOG_PREF"/d' /tmp/sm.conf.new
  LINES_AFTER=$(wc -l < /tmp/sm.conf.new)
  if [ "$LINES_AFTER" -eq $((LINES_BEFORE - N_BEFORE)) ] && grep -q 'libpatch-blmjciaapa' /tmp/sm.conf.new
  then
    cp /tmp/sm.conf.new /jci/sm/sm.conf && log "sm.conf: $N_BEFORE LOG_PREF line(s) removed"
  else
    log "sm.conf: LOG_PREF removal check failed — left as is"
  fi
  rm -f /tmp/sm.conf.new
else
  log "sm.conf: no LOG_PREF present"
fi
grep -A3 'name="jciAAPA"' /jci/sm/sm.conf >> "${LOG}"
grep -A2 'name="aap_service"' /jci/sm/sm.conf >> "${LOG}"
sync
mount -o ro,remount / 2>/dev/null

log "=== CLEAN MODE DONE ==="
sync
mount -o ro,remount ${MYDIR} 2>/dev/null
sync

msg "DONE! oem-aa-mod is in clean mode.\n\nRemove the USB drive.\nThe system will reboot in 10 seconds."
sleep 10
killall -q jci-dialog
reboot &
exit 0
