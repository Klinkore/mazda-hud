#!/bin/sh
# oem-aa-mod fw70 port — UNINSTALL (restore stock sm.conf and AA attributes XML)

MYDIR=$(dirname "$(readlink -f "$0")")
mount -o rw,remount ${MYDIR}
SRC="${MYDIR}/oem-aa-mod"
DST="/data_persist/oem-aa-mod"
LOG="${MYDIR}/uninstall_log.txt"

msg()
{
  killall -q jci-dialog
  /jci/tools/jci-dialog --info --title="oem-aa-mod FW70 uninstall" --text="$*" --no-cancel &
}
log()
{
  echo "$(date +'%D %T') $*" >> "${LOG}"
}

log "=== UNINSTALL START ==="
msg "Removing oem-aa-mod...\nPlease wait."

# Save logs/state to USB first
mkdir -p "${MYDIR}/oem-aa-mod-logs"
cp /tmp/oem-aa-mod.log "${MYDIR}/oem-aa-mod-logs/" 2>/dev/null
cp -a ${DST}/crashes ${DST}/bootcount "${MYDIR}/oem-aa-mod-logs/" 2>/dev/null

# Kill switch first: even if something below fails, the shim stays inert.
touch "${DST}/disabled" 2>/dev/null
sync

mount -o rw,remount /

# --- sm.conf ---
if [ -f "${DST}/backup/sm.conf" ]
then
  cp -a "${DST}/backup/sm.conf" /jci/sm/sm.conf && log "sm.conf restored from backup"
else
  sed -i '/libpatch-blmjciaapa/d' /jci/sm/sm.conf && log "LD_PRELOAD line removed from sm.conf"
fi
grep -q 'libpatch-blmjciaapa' /jci/sm/sm.conf && log "WARNING: sm.conf still references the shim"

# --- XML ---
if [ -f "${DST}/backup/aap_system_attributes.xml" ]
then
  cp -a "${DST}/backup/aap_system_attributes.xml" /etc/aap_system_attributes.xml && log "xml restored from backup"
elif [ -f "${SRC}/aap_system_attributes.xml.stock" ]
then
  cp "${SRC}/aap_system_attributes.xml.stock" /etc/aap_system_attributes.xml && log "xml restored from USB stock copy"
fi
sync

# Library itself: remove (keep backup folder)
rm -f "${DST}/libpatch-blmjciaapa.so" "${DST}/debug"
sync
mount -o ro,remount / 2>/dev/null
log "=== UNINSTALL COMPLETE ==="
sync

msg "UNINSTALL COMPLETE!\n\nRemove the USB drive.\nThe system will reboot in 10 seconds."
sleep 10
killall -q jci-dialog
reboot &
exit 0
