#!/bin/sh
# HUD-dump #2: READ-ONLY. Collects service-manager binaries and device lists.
# Changes nothing in the system. Writes only to the USB drive (hud_dump2/).

MYDIR=$(dirname "$(readlink -f "$0")")
mount -o rw,remount ${MYDIR}
OUT="${MYDIR}/hud_dump2"
mkdir -p "${OUT}/files"
LOG="${OUT}/log.txt"

msg()
{
  killall -q jci-dialog
  /jci/tools/jci-dialog --info --title="HUD-DUMP 2 (read only)" --text="$*" --no-cancel &
}
log()
{
  echo "$(date +'%D %T') $*" >> "${LOG}"
}
grab()
{
  if [ -e "$1" ]
  then
    mkdir -p "${OUT}/files$(dirname "$1")"
    cp -L "$1" "${OUT}/files$1" 2>> "${LOG}" && log "OK   $1" || log "FAIL $1"
  else
    log "MISS $1"
  fi
}
run()
{
  _n="$1"; shift
  ( "$@" ) > "${OUT}/${_n}.txt" 2>&1
}

msg "Collecting service manager files to USB...\nNothing is changed in the system.\nPlease wait ~1 minute."
log "=== START ==="

# --- Service manager (does it support <environ_var>?) ---
grab /jci/sm/sm
grab /jci/sm/sm_svclauncher
run ls_jci_sm ls -la /jci/sm
run which_smctl sh -c 'ls -la /usr/bin/smctl /jci/sm/smctl /jci/tools/smctl /usr/sbin/smctl 2>&1; which smctl 2>&1'
grab /tmp/smevents.txt

# --- Touchscreen device ---
run ls_dev_input ls -la /dev/input
run proc_input cat /proc/bus/input/devices

# --- C / C++ runtime versions ---
run ls_lib sh -c 'ls -la /lib | grep -e libc -e "ld-" -e libgcc -e libdl -e librt -e libpthread -e libm; ls -la /usr/lib | grep -e libstdc'
grab /lib/libc.so.6
grab /usr/lib/libstdc++.so.6

# --- Navigation SD / svcjcinavi presence ---
run ls_navi sh -c 'ls -la /jci/navi /tmp/mnt/sd_nav 2>&1 | head -40'

# --- Free space on /data_persist and root ---
run df df -h
run ls_data_persist sh -c 'ls -la /mnt/data_persist/ 2>&1'

log "=== END ==="
sync
/bin/fsync "${LOG}" 2>/dev/null
sync

msg "DONE!\nFiles saved to USB: hud_dump2\nNothing was changed.\nYou can remove the USB drive now."
sleep 10
killall -q jci-dialog
exit 0
