#!/bin/sh
# oem-aa-mod fw70 port — COLLECT LOGS (read only, no reboot)

MYDIR=$(dirname "$(readlink -f "$0")")
mount -o rw,remount ${MYDIR}
OUT="${MYDIR}/oem-aa-mod-logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${OUT}"

killall -q jci-dialog
/jci/tools/jci-dialog --info --title="oem-aa-mod logs" --text="Copying logs to USB..." --no-cancel &

cp /tmp/oem-aa-mod.log "${OUT}/" 2>/dev/null
ls -la /data_persist/oem-aa-mod/ > "${OUT}/data_persist_ls.txt" 2>&1
cp -a /data_persist/oem-aa-mod/crashes /data_persist/oem-aa-mod/bootcount "${OUT}/" 2>/dev/null
grep -A3 'name="jciAAPA"' /jci/sm/sm.conf > "${OUT}/sm_jciAAPA.txt" 2>&1
cp /etc/aap_system_attributes.xml "${OUT}/" 2>/dev/null
cp /tmp/smevents.txt "${OUT}/" 2>/dev/null
ps > "${OUT}/ps.txt" 2>&1
for p in /proc/[0-9]*; do grep -q jciAAPA $p/cmdline 2>/dev/null && { echo "== $p"; grep -i -e aap -e libpatch $p/maps; }; done > "${OUT}/jciAAPA_maps.txt" 2>&1
sync

killall -q jci-dialog
/jci/tools/jci-dialog --info --title="oem-aa-mod logs" --text="DONE! Logs saved to USB.\nYou can remove the USB drive." --no-cancel &
sleep 8
killall -q jci-dialog
exit 0
