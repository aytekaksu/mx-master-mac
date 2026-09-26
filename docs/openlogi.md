# Set up OpenLogi

Use **OpenLogi 0.8.8 or newer**. MX Master Mac supports either OpenLogi or Logi Options+; run only one provider at a time. Quitting the Options+ window alone does not stop its background agent. When switching permanently, [uninstall Options+](https://support.logi.com/hc/en-ph/articles/9926497851159-Uninstalling-Logi-Options) first and restart if its agent remains running.

## Keep your existing mouse preferences

Changing providers does **not** import your Options+ settings. Before uninstalling Options+, save a backup and note your pointer speed/DPI, vertical and thumb-wheel directions, SmartShift sensitivity, wheel resistance, and button assignments. OpenLogi has its own settings and defaults; the top wheel-mode button can otherwise become a DPI button.

Restore those preferences in OpenLogi as well as the two macro buttons below. For the familiar MX Master controls, its bindings can include:

```toml
DpiToggle = "ToggleSmartShift"
MiddleClick = "MiddleClick"
Back = "BrowserBack"
Forward = "BrowserForward"
```

OpenLogi's SmartShift sensitivity is a raw hardware threshold, **not the same scale** as Options+'s percentage. Its vertical inversion is relative to macOS's scrolling direction. Change the mouse setting in OpenLogi instead of changing the shared macOS/trackpad preference.

OpenLogi 0.8.8 does not expose every Options+ setting. In particular, there is no saved global haptic-strength control or independent horizontal-only smoothing switch. Keep your Options+ backup until the mouse feels right; this release does not promise a complete automatic preference migration.

## 1. Let OpenLogi see your mouse

Open OpenLogi from Applications. Grant **OpenLogi Agent** both **Accessibility** and **Input Monitoring** in System Settings → Privacy & Security. The agent is inside:

```text
/Applications/OpenLogi.app/Contents/Library/LoginItems/OpenLogi Agent.app
```

Use the permission screen's **+**, then **Command+Shift+G** to paste that path if needed. The desktop app and the agent have different permission identities. Enable OpenLogi's launch-at-login setting if you want it available after a restart.

Connect the MX Master 4 and let it appear in OpenLogi. Close OpenLogi's settings window before editing its file.

## 2. Set the two held shortcuts

Open `~/.config/openlogi/config.toml` in a text editor. If you set `XDG_CONFIG_HOME`, use the `openlogi/config.toml` under that directory instead. Make a backup first.

In its existing `[app_settings]` section, set these values (replace matching entries; don't add a second section):

```toml
capture_mouse_events = true
mouse_profile_target = "focused"
smooth_scroll = false
vertical_scroll_sensitivity = 14
```

Find the `[devices."…".bindings]` section for your MX Master 4. Keep **your own device key**: it identifies your physical mouse. Add or replace these two entries:

```toml
HapticPanel = { HoldShortcut = "F13" }
GestureButton = { HoldShortcut = "F14" }
```

The **Haptic Panel** is the thumb-rest button; **Gesture Button** is the third side button. Use `HoldShortcut`, not `CustomShortcut`: the layer must stay active until you release the button.

If either button already has a gesture-direction table (for example `[devices."…".bindings.GestureButton]`), remove that button's entire direction table when replacing it with the single held shortcut. Remove F13/F14 button overrides from that mouse's `per_app_bindings` if you want the layers in every app. Leave other devices and bindings alone.

Reopen OpenLogi to load the file; it will show a configuration error if anything is invalid. Reload Hammerspoon after its helper files have been installed.

## 3. Try the controls

Hold the thumb panel and turn the MX wheel one notch each way: browser tabs should change. Hold the third side button and repeat: the app/window switcher should move both ways and select on release. Trackpad clicks and scrolling must remain normal.

OpenLogi's smooth scrolling and non-default vertical sensitivity generate replacement wheel events that lose the original mouse identity. Keep smoothing **off** and vertical sensitivity **14 (1×)** with this release. MX Master Mac deliberately ignores those replacement events to avoid affecting other mice or the trackpad. Your ordinary wheel still scrolls normally.

## Troubleshooting and undo

- No held shortcuts: check the Agent's permissions, use `HoldShortcut`, and ensure Options+'s background agent is stopped.
- Click shortcuts work but wheel shortcuts do not: check smoothing and sensitivity above. Start with the tested MX Master 4 Bluetooth connection; receiver routing is not yet verified.
- Shortcuts depend on pointer position: set `mouse_profile_target = "focused"`.
- Restore your configuration backup and reopen OpenLogi to undo its mappings. Quit Hammerspoon to stop MX Master Mac. To return to Options+, quit OpenLogi Agent first, reinstall/start Options+, and restore its F13/F14 mappings.

The integration was developed against [OpenLogi v0.8.8](https://github.com/AprilNEA/OpenLogi/releases/tag/v0.8.8), commit `7275072f58a18b81deef89b96c5a3d90cfd80dd4`. Its [configuration reference](https://github.com/AprilNEA/OpenLogi/blob/v0.8.8/docs/CONFIGURATION.md) describes the complete TOML format. OpenLogi currently requires file editing for `HoldShortcut` payloads; the MX Master Mac setup app remains on our roadmap.
