#!/bin/zsh
set -eu

if [[ "${EUID}" -ne 0 ]]; then
  print -u2 "Run this installer with sudo."
  exit 77
fi

if ! /usr/sbin/ioreg -r -k product-soc-name -d 1 -w0 2>/dev/null | \
    /usr/bin/grep -q '"product-soc-name" = <"Apple '; then
  print -u2 "GoodMorning supports Apple-silicon Macs only."
  exit 69
fi

if ! /usr/sbin/ioreg -r -c AppleSmartBattery -l -w0 2>/dev/null | \
    /usr/bin/grep -q '"ExternalConnected"'; then
  print -u2 "GoodMorning supports Apple-silicon MacBook models only."
  exit 69
fi

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
script="${project_dir}/goodmorning.zsh"
plist_source="${project_dir}/com.versacecrispies.goodmorning.plist"
plist_target="/Library/LaunchDaemons/com.versacecrispies.goodmorning.plist"
label="com.versacecrispies.goodmorning"
old_label="com.goodmorning.airplay-awake"
old_plist="/Library/LaunchDaemons/com.goodmorning.airplay-awake.plist"

if [[ ! -x "${script}" ]]; then
  print -u2 "goodmorning.zsh is missing or not executable"
  exit 66
fi

/bin/launchctl bootout "system/${label}" 2>/dev/null || true
/bin/launchctl bootout "system/${old_label}" 2>/dev/null || true
# launchd may briefly retain a recently removed job. Waiting avoids its generic
# "Bootstrap failed: 5" response during an in-place upgrade.
/bin/sleep 2

# Migrate installations released under the previous project name.
if [[ -e /var/run/airplay-awake.enabled ]]; then
  /usr/bin/pmset disablesleep 0
  /bin/rm -f /var/run/airplay-awake.enabled
fi
/bin/rm -f /usr/local/libexec/airplay-awake.zsh "${old_plist}"

/usr/bin/install -d -o root -g wheel -m 755 /usr/local/libexec
/usr/bin/install -o root -g wheel -m 755 "${script}" /usr/local/libexec/goodmorning.zsh
/usr/bin/install -o root -g wheel -m 644 "${plist_source}" "${plist_target}"

if ! /bin/launchctl bootstrap system "${plist_target}"; then
  print -u2 "launchd was still releasing the previous job; retrying once..."
  /bin/sleep 3
  /bin/launchctl bootstrap system "${plist_target}"
fi
/bin/launchctl enable "system/${label}"
/bin/launchctl kickstart -k "system/${label}"
/bin/launchctl print "system/${label}" >/dev/null
print "GoodMorning installed. Run './goodmorning.zsh diagnose' while a video is playing over AirPlay to inspect detection."
