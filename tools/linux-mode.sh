# Shared by install.sh and uninstall.sh: both need the device in rooted Android, but it may be running MU300 Linux
# right now (then there is no adb device, only SSH on the USB network). Offer to send it back to Android.
# Uses: say(), die(), ask(), and t() from tools/i18n.sh (loaded here when the caller has not)
command -v t >/dev/null 2>&1 || . "$TOP/tools/i18n.sh"

MU300_IP=${MU300_IP:-192.168.77.1}

# true when something answers on the Linux SSH port of the USB network
linux_mode_running() {
    command -v nc >/dev/null || return 1
    nc -z -G 3 -w 3 "$MU300_IP" 22 >/dev/null 2>&1
}

# ask the running Linux to boot Android next and reboot; then wait for adb
linux_mode_to_android() {
    say "$(t 'The device is running MU300 Linux, not Android')"
    echo "  $(t 'Installing and uninstalling happen from Android (slot a), so the device has to reboot first.')"
    ask go "$(t 'Reboot the device into Android now? (yes/no)')" yes
    [ "$go" = yes ] || die "$(t 'boot Android yourself (on the device: sudo mu300-next-boot android && sudo reboot)')"
    # -t: sudo needs a terminal to ask for the device password, and everything runs in one sudo call so it is
    # asked only once. reboot cuts the connection, so ssh's exit status says nothing: watch the port instead.
    for user in ubuntu root; do
        echo "  $(t '{1} - enter the device password when asked (Ctrl-C to skip)' "$user@$MU300_IP")"
        ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 \
            "$user@$MU300_IP" 'if [ "$(id -u)" = 0 ]; then S=; else S=sudo; fi; $S sh -c "/opt/mu300/bin/mu300-next-boot android && sync && reboot"' || true
        n=0
        while [ $n -lt 8 ]; do
            linux_mode_running || { echo "  $(t 'rebooting')"; break; }
            n=$((n + 1)); sleep 5
        done
        linux_mode_running || break
    done
    if linux_mode_running; then
        die "$(t 'could not reboot it over SSH; on the device run: sudo mu300-next-boot android && sudo reboot')"
    fi
    echo "  $(t 'waiting for Android')"
    n=0
    while [ $n -lt 60 ]; do
        select_device quiet
        [ "$(adb get-state 2>/dev/null)" = device ] && { echo "  $(t 'Android is up')"; return 0; }
        n=$((n + 1)); sleep 5
    done
    die "$(t 'the device did not come back as Android; boot it yourself (mu300-next-boot android)')"
}

# With more than one adb device attached (a phone, an emulator, a device over the network) every plain adb command
# fails with "more than one device/emulator", which read as "no adb device". Pick the F50 and point adb at it with
# ANDROID_SERIAL: the only device, else the only one that says it is an F50/MU300, else ask.
select_device() {  # select_device [quiet]: quiet never asks, it only picks what is unambiguous
    [ -n "${ANDROID_SERIAL:-}" ] && return 0
    _sd_all=$(adb devices -l 2>/dev/null | awk 'NR > 1 && $2 == "device"')
    [ -n "$_sd_all" ] || return 0
    [ "$(printf '%s\n' "$_sd_all" | wc -l | tr -d ' ')" = 1 ] && { export ANDROID_SERIAL=$(printf '%s\n' "$_sd_all" | awk '{print $1}'); return 0; }
    _sd_f50=$(printf '%s\n' "$_sd_all" | grep -E 'model:F50|product:MU300|device:MU300' | awk '{print $1}')
    if [ -n "$_sd_f50" ] && [ "$(printf '%s\n' "$_sd_f50" | wc -l | tr -d ' ')" = 1 ]; then
        export ANDROID_SERIAL=$_sd_f50
        echo "  $(t 'more than one adb device: using {1} (F50/MU300)' "$ANDROID_SERIAL")"
        return 0
    fi
    [ "${1:-}" = quiet ] && return 1
    echo "  $(t 'more than one adb device - which one is the F50?')"
    printf '%s\n' "$_sd_all" | awk '{ m = ""; for (i = 3; i <= NF; i++) if ($i ~ /^model:/) m = substr($i, 7); printf "    %d) %s %s\n", NR, $1, m }'
    ask _sd_n "$(t 'Device')" 1
    _sd_s=$(printf '%s\n' "$_sd_all" | awk -v n="$_sd_n" 'NR == n {print $1}')
    [ -n "$_sd_s" ] || die "$(t 'invalid choice')"
    export ANDROID_SERIAL=$_sd_s
}

# call before anything else that needs adb
require_android() {
    select_device
    [ "$(adb get-state 2>/dev/null)" = device ] && return 0
    linux_mode_running && linux_mode_to_android && return 0
    die "$(t 'no adb device (boot Android, enable USB debugging)')"
}
