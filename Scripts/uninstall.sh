#!/bin/zsh
set -eu

if [[ "${EUID}" -ne 0 ]]; then
  print -u2 "Run this uninstaller with sudo."
  exit 77
fi

plist_target="/Library/LaunchDaemons/com.versacecrispies.goodmorning.plist"

/bin/launchctl bootout system/com.versacecrispies.goodmorning 2>/dev/null || true
/bin/launchctl bootout system/com.goodmorning.airplay-awake 2>/dev/null || true
# Clean up only when our ownership marker remains. Do not clear an override
# that may belong to another administrator or utility.
if [[ -e /var/run/goodmorning.enabled || -e /var/run/airplay-awake.enabled ]]; then
  /usr/bin/pmset disablesleep 0
  /bin/rm -f /var/run/goodmorning.enabled
  /bin/rm -f /var/run/airplay-awake.enabled
fi
/bin/rm -f "${plist_target}"
/bin/rm -f /Library/LaunchDaemons/com.goodmorning.airplay-awake.plist
/bin/rm -f /usr/local/libexec/goodmorning.zsh /usr/local/libexec/airplay-awake.zsh
print "GoodMorning uninstalled and normal sleep behavior restored."
