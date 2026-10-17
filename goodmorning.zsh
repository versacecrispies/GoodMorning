#!/bin/zsh
# Keep a Mac notebook awake with its lid closed only during guarded AirPlay video.

set -u
zmodload zsh/datetime

readonly VERSION="1.2.0"
readonly PROGRAM_NAME="${0:t}"
readonly STATE_FILE="/var/run/goodmorning.enabled"
readonly CHECK_INTERVAL=5
readonly MAX_RUNTIME=21600
readonly MIN_BATTERY=20
readonly SERVICE_LABEL="com.versacecrispies.goodmorning"
readonly SERVICE_PLIST="/Library/LaunchDaemons/com.versacecrispies.goodmorning.plist"

typeset -a DEDICATED_VIDEO_PLAYERS=(
  "TV" "com.apple.TV" "QuickTime Player" "VLC" "IINA" "mpv"
  "Plex" "Plex HTPC" "Infuse" "Stremio" "Kodi" "Movist Pro"
)
typeset -a BROWSER_PLAYERS=(
  "Safari" "WebKit.WebContent" "com.apple.WebKit.WebContent"
  "Google Chrome" "Google Chrome Helper" "Chromium" "Chromium Helper"
  "Brave Browser" "Brave Browser Helper" "Microsoft Edge"
  "Microsoft Edge Helper" "Firefox" "FirefoxCP Web Content"
  "Arc" "Arc Helper" "Orion" "Opera" "Opera Helper"
)
typeset -a VIDEO_WORDS=(
  "video" "movie" "media playback" "playing media" "avfoundation" "webrtc"
  "power save blocker" "video wake lock"
)

typeset -g OWNS_OVERRIDE=0
typeset -g ARMED_AT=0
typeset -g POSITIVE_SAMPLES=0
typeset -g NEGATIVE_SAMPLES=0
typeset -g NEEDS_REARM=0
typeset -g LAST_SUMMARY=""
typeset -g SNAP_AIRPLAY=0 SNAP_PLAYER="none" SNAP_AC=0 SNAP_BATTERY=-1 SNAP_THERMAL=3

log() {
  print -u2 -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

has_airplay_session() {
  local displays="${(L)1}" gpu_clients="${(L)2}"
  [[ "${displays}" == *spdisplays_airplay* ||
     "${displays}" == *'"airplay display"'* ||
     "${displays}" == *airplaydisplay* ||
     "${gpu_clients}" == *'iouserclientcreator" = "pid '*'airplayxpchelper"'* ]]
}

video_assertion_owner() {
  local assertions="$1" line lower owner owner_lower player word
  local is_dedicated is_browser has_video_word
  while IFS= read -r line; do
    lower="${(L)line}"
    [[ "${lower}" == *preventuseridledisplaysleep* && "${lower}" == *named:* ]] || continue

    # pmset formats owners as: pid 123(Process Name): [...]
    if [[ "${line}" =~ 'pid [0-9]+\((.+)\):' ]]; then
      owner="${match[1]}"
    else
      continue
    fi
    owner_lower="${(L)owner}"

    is_dedicated=0
    for player in "${DEDICATED_VIDEO_PLAYERS[@]}"; do
      if [[ "${owner_lower}" == "${(L)player}" ||
            "${owner_lower}" == "${(L)player}"' helper'* ]]; then
        is_dedicated=1
        break
      fi
    done

    # A dedicated video player requesting display wake is itself a sufficiently
    # narrow signal. This catches QuickTime/VLC even when their assertion names
    # change between macOS or app releases.
    if (( is_dedicated )); then
      print -r -- "${owner}"
      return 0
    fi

    is_browser=0
    for player in "${BROWSER_PLAYERS[@]}"; do
      if [[ "${owner_lower}" == "${(L)player}" ||
            "${owner_lower}" == "${(L)player}"' helper'* ||
            "${owner_lower}" == "${(L)player}"' ('* ]]; then
        is_browser=1
        break
      fi
    done
    (( is_browser )) || continue

    # Browsers can expose unrelated Wake Lock requests. Require the assertion
    # name to identify media/video before allowing one to qualify.
    has_video_word=0
    for word in "${VIDEO_WORDS[@]}"; do
      [[ "${lower}" == *"${word}"* ]] && has_video_word=1 && break
    done
    if (( has_video_word )); then
      print -r -- "${owner}"
      return 0
    fi
  done <<< "${assertions}"
  return 1
}

thermal_state() {
  local result
  result="$(/usr/bin/osascript -l JavaScript \
    -e 'ObjC.import("Foundation"); Number($.NSProcessInfo.processInfo.thermalState)' 2>/dev/null)" || result=3
  [[ "${result}" == <0-3> ]] || result=3
  print -r -- "${result}"
}

external_power_connected() {
  [[ "$1" == *'"ExternalConnected" = Yes'* ]]
}

is_apple_silicon() {
  /usr/sbin/ioreg -r -k product-soc-name -d 1 -w0 2>/dev/null | \
    /usr/bin/grep -q '"product-soc-name" = <"Apple '
}

take_snapshot() {
  local displays gpu_clients assertions battery power_source percent
  displays="$(/usr/sbin/system_profiler SPDisplaysDataType -json 2>/dev/null)"
  # Control Center screen mirroring is not listed as an AirPlay display on all
  # macOS releases. During an active mirror, AirPlayXPCHelper owns a GPU client.
  gpu_clients="$(/usr/sbin/ioreg -r -c AGXDeviceUserClient -l -w0 2>/dev/null)"
  assertions="$(/usr/bin/pmset -g assertions 2>/dev/null)"
  battery="$(/usr/bin/pmset -g batt 2>/dev/null)"
  power_source="$(/usr/sbin/ioreg -r -c AppleSmartBattery -l -w0 2>/dev/null)"

  has_airplay_session "${displays}" "${gpu_clients}" && SNAP_AIRPLAY=1 || SNAP_AIRPLAY=0
  SNAP_PLAYER="$(video_assertion_owner "${assertions}")" || SNAP_PLAYER="none"
  external_power_connected "${power_source}" && SNAP_AC=1 || SNAP_AC=0
  if [[ "${battery}" =~ '([0-9]{1,3})%' ]]; then
    SNAP_BATTERY="${match[1]}"
  else
    SNAP_BATTERY=-1
  fi
  SNAP_THERMAL="$(thermal_state)"
}

thermal_name() {
  case "$1" in
    0) print nominal ;;
    1) print fair ;;
    2) print serious ;;
    3) print critical-or-unavailable ;;
    *) print unknown ;;
  esac
}

snapshot_safe() {
  (( SNAP_AIRPLAY == 1 && SNAP_AC == 1 && SNAP_BATTERY > MIN_BATTERY && SNAP_THERMAL <= 1 )) &&
    [[ "${SNAP_PLAYER}" != "none" ]]
}

sleep_is_disabled() {
  /usr/sbin/ioreg -r -k SleepDisabled -d 1 2>/dev/null | /usr/bin/grep -q '"SleepDisabled" = Yes'
}

recover_stale_override() {
  [[ -e "${STATE_FILE}" ]] || return 0
  log "recovering an override left by an interrupted run"
  /usr/bin/pmset disablesleep 0 || log "WARNING: could not clear stale override"
  /bin/rm -f "${STATE_FILE}"
}

arm() {
  (( OWNS_OVERRIDE == 0 )) || return 0
  if sleep_is_disabled; then
    log "sleep is already disabled by something else; refusing to take ownership"
    NEEDS_REARM=1
    return 0
  fi
  print -r -- "pid=$$" > "${STATE_FILE}" || {
    log "cannot create safety state file"
    return 1
  }
  if ! /usr/bin/pmset disablesleep 1; then
    /bin/rm -f "${STATE_FILE}"
    log "pmset refused the sleep override"
    return 1
  fi
  if ! sleep_is_disabled; then
    /bin/rm -f "${STATE_FILE}"
    log "pmset returned success but macOS did not apply the override"
    return 1
  fi
  OWNS_OVERRIDE=1
  ARMED_AT=${EPOCHSECONDS}
  log "armed closed-lid sleep override"
}

disarm() {
  local reason="${1:-service stopped}"
  (( OWNS_OVERRIDE == 1 )) || return 0
  /usr/bin/pmset disablesleep 0 || log "WARNING: could not restore normal sleep"
  /bin/rm -f "${STATE_FILE}"
  OWNS_OVERRIDE=0
  ARMED_AT=0
  log "restored normal sleep: ${reason}"
}

tick() {
  local summary hazard=0
  take_snapshot
  summary="airplay=$(( SNAP_AIRPLAY )) video=${SNAP_PLAYER} ac=$(( SNAP_AC )) battery=${SNAP_BATTERY}% thermal=$(thermal_name "${SNAP_THERMAL}")"
  if [[ "${summary}" != "${LAST_SUMMARY}" ]]; then
    log "${summary}"
    LAST_SUMMARY="${summary}"
  fi

  if (( OWNS_OVERRIDE == 1 && EPOCHSECONDS - ARMED_AT >= MAX_RUNTIME )); then
    disarm "six-hour safety limit reached"
    NEEDS_REARM=1
  fi

  if snapshot_safe && (( NEEDS_REARM == 0 )); then
    (( POSITIVE_SAMPLES += 1 ))
    NEGATIVE_SAMPLES=0
    (( POSITIVE_SAMPLES >= 2 )) && arm
  else
    POSITIVE_SAMPLES=0
    (( NEGATIVE_SAMPLES += 1 ))
    (( SNAP_AC == 0 || SNAP_BATTERY <= MIN_BATTERY || SNAP_THERMAL >= 2 )) && hazard=1
    (( hazard == 1 || NEGATIVE_SAMPLES >= 2 )) && disarm "guard condition no longer satisfied"
    if (( SNAP_AIRPLAY == 0 )) || [[ "${SNAP_PLAYER}" == "none" ]]; then
      NEEDS_REARM=0
    fi
  fi
}

self_test() {
  local failures=0 owner
  is_apple_silicon || (( failures += 1 ))
  has_airplay_session '{"spdisplays_display_type":"spdisplays_airplay"}' '' || (( failures += 1 ))
  has_airplay_session '{"_name":"Built-in Liquid Retina Display"}' '' && (( failures += 1 ))
  has_airplay_session '' '"IOUserClientCreator" = "pid 123, AirPlayXPCHelper"' || (( failures += 1 ))
  external_power_connected '"ExternalConnected" = Yes' || (( failures += 1 ))
  external_power_connected '"ExternalConnected" = No' && (( failures += 1 ))
  owner="$(video_assertion_owner 'pid 99(Safari): [0x1] PreventUserIdleDisplaySleep named: "Media Playback video"')" || true
  [[ "${owner}" == "Safari" ]] || (( failures += 1 ))
  owner="$(video_assertion_owner 'pid 99(com.apple.WebKit.WebContent): [0x1] PreventUserIdleDisplaySleep named: "Media Playback"')" || true
  [[ "${owner}" == "com.apple.WebKit.WebContent" ]] || (( failures += 1 ))
  owner="$(video_assertion_owner 'pid 99(Google Chrome Helper (Renderer)): [0x1] PreventUserIdleDisplaySleep named: "Video Wake Lock"')" || true
  [[ "${owner}" == "Google Chrome Helper (Renderer)" ]] || (( failures += 1 ))
  owner="$(video_assertion_owner 'pid 99(QuickTime Player): [0x1] PreventUserIdleDisplaySleep named: "Playback"')" || true
  [[ "${owner}" == "QuickTime Player" ]] || (( failures += 1 ))
  owner="$(video_assertion_owner 'pid 99(VLC): [0x1] PreventUserIdleDisplaySleep named: "display assertion"')" || true
  [[ "${owner}" == "VLC" ]] || (( failures += 1 ))
  owner="$(video_assertion_owner 'pid 99(Stremio): [0x1] PreventUserIdleDisplaySleep named: "Power Save Blocker"')" || true
  [[ "${owner}" == "Stremio" ]] || (( failures += 1 ))
  video_assertion_owner 'pid 99(Safari): [0x1] PreventUserIdleDisplaySleep named: "Presentation Wake Lock"' >/dev/null && (( failures += 1 ))
  video_assertion_owner 'pid 99(AirPlayUIAgent): [0x1] PreventUserIdleDisplaySleep named: "com.apple.airplay.disableUserIdleDisplaySleep"' >/dev/null && (( failures += 1 ))
  video_assertion_owner 'pid 99(Music): [0x1] PreventUserIdleDisplaySleep named: "Media Playback video"' >/dev/null && (( failures += 1 ))
  SNAP_AIRPLAY=1 SNAP_PLAYER="Safari" SNAP_AC=1 SNAP_BATTERY=80 SNAP_THERMAL=0
  snapshot_safe || (( failures += 1 ))
  SNAP_PLAYER="none"
  snapshot_safe && (( failures += 1 ))
  if (( failures == 0 )); then
    print "all tests passed"
    return 0
  fi
  print -u2 -- "${failures} test(s) failed"
  return 1
}

usage() {
  print -- "GoodMorning ${VERSION}
Usage:
  ${PROGRAM_NAME} diagnose          Check the current guard conditions
  ${PROGRAM_NAME} status            Show whether the watchdog and override are active
  sudo ${PROGRAM_NAME} on           Enable and start the watchdog
  sudo ${PROGRAM_NAME} off          Stop and disable the watchdog
  sudo ${PROGRAM_NAME} toggle       Switch the watchdog on or off
  ${PROGRAM_NAME} --self-test       Run detection tests"
}

service_is_running() {
  /bin/launchctl print "system/${SERVICE_LABEL}" >/dev/null 2>&1
}

service_status() {
  local service_state="stopped" override_state="inactive"
  service_is_running && service_state="running"
  [[ -e "${STATE_FILE}" ]] && override_state="active"
  print -- "watchdog=${service_state} sleep_override=${override_state}"
}

require_root_control() {
  (( EUID == 0 )) || {
    print -u2 -- "This command needs administrator access. Run: sudo ${PROGRAM_NAME} $1"
    exit 77
  }
}

service_on() {
  require_root_control on
  [[ -f "${SERVICE_PLIST}" ]] || {
    print -u2 -- "GoodMorning is not installed. Run: sudo ./Scripts/install.sh"
    exit 66
  }
  /bin/launchctl enable "system/${SERVICE_LABEL}"
  if ! service_is_running; then
    /bin/launchctl bootstrap system "${SERVICE_PLIST}"
  fi
  print "GoodMorning is on."
  service_status
}

service_off() {
  require_root_control off
  /bin/launchctl disable "system/${SERVICE_LABEL}"
  /bin/launchctl bootout "system/${SERVICE_LABEL}" 2>/dev/null || true
  /bin/sleep 1
  # A graceful stop removes this marker itself. If it remains after a crash or
  # forced stop, clear only the override that GoodMorning recorded as its own.
  if [[ -e "${STATE_FILE}" ]]; then
    /usr/bin/pmset disablesleep 0
    /bin/rm -f "${STATE_FILE}"
  fi
  print "GoodMorning is off. Normal sleep behavior is active."
  service_status
}

case "${1:-}" in
  run)
    is_apple_silicon || {
      print -u2 "GoodMorning supports Apple-silicon Macs only"
      exit 69
    }
    (( EUID == 0 )) || { print -u2 "run must be started as root (use the installer)"; exit 77; }
    recover_stale_override
    trap 'disarm "service stopped"; exit 0' TERM INT HUP
    trap 'disarm "service exited"' EXIT
    while true; do
      tick
      /bin/sleep "${CHECK_INTERVAL}"
    done
    ;;
  diagnose)
    take_snapshot
    if snapshot_safe; then
      print -- "airplay=$(( SNAP_AIRPLAY )) video=${SNAP_PLAYER} ac=$(( SNAP_AC )) battery=${SNAP_BATTERY}% thermal=$(thermal_name "${SNAP_THERMAL}") eligible=true"
    else
      print -- "airplay=$(( SNAP_AIRPLAY )) video=${SNAP_PLAYER} ac=$(( SNAP_AC )) battery=${SNAP_BATTERY}% thermal=$(thermal_name "${SNAP_THERMAL}") eligible=false"
    fi
    ;;
  status)
    service_status
    ;;
  on)
    service_on
    ;;
  off)
    service_off
    ;;
  toggle)
    require_root_control toggle
    if service_is_running; then
      service_off
    else
      service_on
    fi
    ;;
  --self-test)
    self_test
    ;;
  *)
    usage
    [[ -z "${1:-}" ]] || exit 64
    ;;
esac
