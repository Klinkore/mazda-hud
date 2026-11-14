#!/bin/sh
# HUD-dump: READ-ONLY collection of Android Auto / HUD files from CMU.
# Changes nothing in the system. Writes only to the USB drive (hud_dump/).

hwclock --hctosys 2>/dev/null

MYDIR=$(dirname "$(readlink -f "$0")")
mount -o rw,remount ${MYDIR}
OUT="${MYDIR}/hud_dump"
mkdir -p "${OUT}/files"
LOG="${OUT}/log.txt"

msg()
{
  killall -q jci-dialog
  /jci/tools/jci-dialog --info --title="HUD-DUMP (read only)" --text="$*" --no-cancel &
}
log()
{
  echo "$(date +'%D %T') $*" >> "${LOG}"
}
grab()
{
  # grab <path>: copy file into OUT/files keeping full path
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
  # run <name> <command...>: save command output
  _n="$1"; shift
  ( "$@" ) > "${OUT}/${_n}.txt" 2>&1
}

msg "Collecting Android Auto / HUD files to USB...\nNothing is changed in the system.\nPlease wait ~1 minute."
log "=== START ==="

# --- Versions / system info ---
grab /jci/version.ini
run uname uname -a
run df df -h
run cpuinfo cat /proc/cpuinfo
run ps ps
run mount mount

# --- Android Auto configs ---
grab /etc/aap_system_attributes.xml
grab /etc/aap_system_attributes_UCP.xml
run ls_etc_aap sh -c 'ls -la /etc/aap* /etc/*aap* 2>&1'
run ls_androidauto ls -laR /etc/androidauto

# --- Service manager configs ---
grab /jci/sm/sm.conf
grab /jci/sm/sm_WCP.conf
run ls_jci_sm ls -la /jci/sm

# --- Android Auto binaries ---
grab /usr/lib/libaap_interface.so
grab /usr/bin/aap_service
grab /jci/aapa/blmjciaapa.so
run ls_jci_aapa ls -laR /jci/aapa
run ls_usr_lib_aap sh -c 'ls -la /usr/lib | grep -i -e aap -e jcidbus -e vbsnavi -e navi -e dbus'

# --- HUD / navi client libraries ---
for f in $(find /usr/lib /lib /jci -name 'libjcivbsnaviclient*' -o -name 'libjcidbus*' -o -name 'libdbus-1*' 2>/dev/null)
do
  grab "$f"
done
run find_navi sh -c 'find /jci /usr -name "*navi*" 2>/dev/null'

# --- D-Bus introspection (read only) ---
run introspect_vbs_navi dbus-send --bus=unix:path=/tmp/dbus_service_socket --print-reply --dest=com.jci.vbs.navi /com/jci/vbs/navi org.freedesktop.DBus.Introspectable.Introspect
run introspect_navi2IHU dbus-send --bus=unix:path=/tmp/dbus_hmi_socket --print-reply --dest=com.jci.navi2IHU /com/jci/navi2IHU org.freedesktop.DBus.Introspectable.Introspect
run dbus_tools sh -c 'ls -la /usr/bin/dbus-*'

# --- Existing tweaks / SSH state (no passwords copied) ---
run ls_data_persist ls -la /data_persist
run ssh_state sh -c 'ls -la /etc/ssh 2>&1; grep -c "^jci:" /config-mfg/passwd 2>&1; grep -c "^cmu:" /config-mfg/passwd 2>&1; ps | grep -i ssh'
run net sh -c 'ifconfig -a 2>&1; ls /jci/scripts | grep -i -e wifi -e fw'

log "=== END ==="
sync
/bin/fsync "${LOG}" 2>/dev/null
sync

msg "DONE!\nFiles saved to USB: hud_dump\nNothing was changed.\nYou can remove the USB drive now."
sleep 10
killall -q jci-dialog
exit 0
