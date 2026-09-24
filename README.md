# ClickFocus

A small macOS background agent that makes sure the window you click is the
window that gets focus.

Some apps respond to being activated by restoring the window they last had
focused. With Chrome profiles open on two displays, clicking the window on one
display while another app is active can focus Chrome's other window instead,
so your typing lands in the wrong profile. ClickFocus notices when that happens
and focuses the window you clicked.

## How it works

ClickFocus listens for left mouse-down events without altering or delaying
them. When a click lands on a standard window of an app that isn't active, it
records that app's other windows and checks the app's focused window every
10ms for the next 500ms. If the app focuses one of those other windows,
ClickFocus raises and focuses the clicked window, at most three times per
click. A window the click opens, such as a new window or a dialog, keeps its
focus.

Clicks inside the already active app are left alone.

## Install

Requires macOS 13 or later and the Xcode command line tools.

```sh
make install
```

This builds `ClickFocus.app`, copies it to `~/Applications` and installs a
LaunchAgent that starts it at login and restarts it if it exits.

On first run macOS asks for Accessibility permission. Enable ClickFocus in
System Settings > Privacy & Security > Accessibility; it notices within a few
seconds and starts working.

To remove it:

```sh
make uninstall
```

## Keeping the permission across rebuilds

An ad-hoc signed build looks like a new app to macOS each time it changes, so
the Accessibility permission has to be granted again after every rebuild. If a
code-signing identity named `ClickFocus Code Signing` is in your keychain, the
Makefile signs with it instead and the permission carries over. A self-signed
certificate is enough:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout key.pem -out cert.pem -subj "/CN=ClickFocus Code Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
  -name "ClickFocus Code Signing" -out cert.p12 -passout pass:clickfocus
security import cert.p12 -k ~/Library/Keychains/login.keychain-db \
  -P clickfocus -T /usr/bin/codesign
rm key.pem cert.pem cert.p12
```

Pass `SIGN_IDENTITY=<name>` to `make` to sign with a different identity.

## Options

```
ClickFocus [--apps <bundleId,...>] [--verbose]

  --apps     only act on these apps, e.g. com.google.Chrome (default: all apps)
  --verbose  log every click that is inspected
```

To run the installed agent with options, add them to `ProgramArguments` in
`~/Library/LaunchAgents/com.tomk.ClickFocus.plist`, then restart it:

```sh
launchctl kickstart -k gui/$(id -u)/com.tomk.ClickFocus
```

`make run` builds and runs ClickFocus in the foreground with `--verbose`.

## Logs

The installed agent logs to `~/Library/Logs/ClickFocus.log`. Each correction
is logged with the window the app focused, the window ClickFocus focused
instead, and the time since the click:

```
click 2: app focused "Tom - Google Chrome", focused "Work - Google Chrome" at 176ms
```
