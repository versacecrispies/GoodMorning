# GoodMorning

GoodMorning keeps an Apple-silicon MacBook running with its lid closed while
a video is being mirrored to an AirPlay display. It behaves like a small,
guarded version of clamshell mode for wireless playback: the sleep override is
enabled only while a recognized video session is active and is removed as soon
as the required conditions disappear.

This project exists because `caffeinate` can prevent idle sleep, but it does not
reliably override the sleep triggered by closing a MacBook lid.

## Requirements

- An Apple-silicon MacBook Air or MacBook Pro
- A recent version of macOS
- An active AirPlay or Control Center screen-mirroring session
- External power connected
- More than 20% battery remaining
- A supported player actively playing video

The installer intentionally rejects Intel Macs and desktop Macs. The project is
currently verified on a 14-inch M3 MacBook Pro running macOS 27.0.1.

## Supported players

Dedicated video players:

- Apple TV
- QuickTime Player
- VLC
- IINA
- mpv
- Plex and Plex HTPC
- Infuse
- Stremio
- Kodi
- Movist Pro

Supported browser families:

- Safari and WebKit
- Chrome and Chromium
- Brave
- Microsoft Edge
- Firefox
- Arc
- Orion
- Opera

Dedicated players qualify when they own an active macOS display-sleep
assertion. Browsers must also identify the assertion as video or media playback;
a normal webpage or presentation wake lock is not enough.

## Safety behavior

The watchdog checks the system every five seconds and enables the closed-lid
override only after two consecutive valid checks. It restores normal sleep when
any of the following occurs:

- video playback stops;
- AirPlay or screen mirroring disconnects;
- external power is removed;
- the battery reaches 20%;
- macOS reports serious or critical thermal pressure; or
- the six-hour continuous session limit is reached.

After the six-hour limit, playback must stop or AirPlay must disconnect before
the watchdog can arm again. A state file also allows the service to recover an
override left behind by an interrupted process.

Keep the MacBook on a hard, ventilated surface. Never use closed-lid playback
while the computer is inside a bag, sleeve, or other enclosed space.

## Check compatibility

Run the self-test:

```sh
./goodmorning.zsh --self-test
```

Then start screen mirroring and play a video:

```sh
./goodmorning.zsh diagnose
```

A fully eligible session looks like this:

```text
airplay=1 video=Safari ac=1 battery=84% thermal=nominal eligible=true
```

Diagnosis is read-only. If it reports `video=none`, the current player is not
publishing a recognized playback assertion and the watchdog will remain off.

## Install

From the project directory, run:

```sh
sudo ./Scripts/install.sh
```

The installer copies the watchdog to `/usr/local/libexec`, installs a launch
daemon in `/Library/LaunchDaemons`, and starts the service. Logs are written to:

```text
/var/log/goodmorning.log
```

Check the latest activity with:

```sh
tail -f /var/log/goodmorning.log
```

## Turn the watchdog on or off

Installation turns GoodMorning on by default. Check its current state with:

```sh
./goodmorning.zsh status
```

Use the persistent toggle to switch it between running and stopped:

```sh
sudo ./goodmorning.zsh toggle
```

You can also choose the state explicitly:

```sh
sudo ./goodmorning.zsh on
sudo ./goodmorning.zsh off
```

The `off` command unloads the watchdog, disables automatic startup across
reboots, and restores normal sleep if GoodMorning owns the active override. It
does not uninstall any files. The `on` command enables automatic startup and
loads the watchdog again.

When the override is active, this command reports `SleepDisabled = Yes`:

```sh
ioreg -r -k SleepDisabled -d 1 | grep SleepDisabled
```

## Uninstall

```sh
sudo ./Scripts/uninstall.sh
```

The uninstaller stops the daemon, removes the installed files, and restores
normal sleep if GoodMorning owns the active override.

## How it works

GoodMorning combines several independent macOS signals instead of trusting a
single application:

1. It confirms an AirPlay display or active AirPlay GPU mirroring session.
2. It reads macOS power assertions to identify active video playback.
3. It checks external power and battery state through the battery controller.
4. It reads the system thermal-pressure state.
5. It uses `pmset disablesleep` only while every guard condition remains valid.

The service fails closed. Unknown players, missing system information, or an
unrecognized playback signal leave normal sleep behavior enabled.

## Limitations

Closed-lid AirPlay is not a standard macOS clamshell configuration. The project
uses system behavior that may change in future macOS releases, so test the
diagnostic command after major system updates.

Player support depends on the power assertion published by each application.
If a player changes its process or assertion name, it may need a new detection
rule. Reports from other Apple-silicon MacBook models and macOS versions are
welcome.

## License

GoodMorning is available under the [MIT License](LICENSE).
