# MX Master Mac

**The way to use your MX Master 4 on a Mac—without missing the trackpad.**

Switch browser tabs and windows, and use everyday shortcuts, right from your mouse. Hold a side button and use the wheel or clicks; release it to use the mouse normally again. The helper identifies MX input so your trackpad keeps working. This first release needs manual setup, Logi Options+, Hammerspoon, and AltTab. There is no Hammerspoon pop-up UI.

## Controls

| Hold | MX wheel up / down | MX left / right click |
| --- | --- | --- |
| Thumb button | Next / previous browser tab | Close / new tab |
| Third side button | Previous / next window in AltTab; select on release | Copy / paste |

While holding the third side button, click **left and right together** to select all. Click shortcuts use the usual macOS Command shortcuts in the active app.

## Requirements

- MX Master 4, [Logi Options+](https://www.logitech.com/software/logi-options-plus.html), [Hammerspoon](https://www.hammerspoon.org/), and [AltTab](https://alt-tab-macos.netlify.app/).
- Hammerspoon in `/Applications/Hammerspoon.app` and AltTab in `/Applications/AltTab.app`.
- Xcode Command Line Tools to build the helper (`xcode-select --install` if needed).
- macOS Accessibility and Input Monitoring permissions for the helper and Hammerspoon; Accessibility and Screen Recording for AltTab. macOS may ask for Automation permission when switching Vivaldi tabs.

This version was tested on one Apple Silicon Mac with AltTab 11.6.1. The helper currently recognizes the MX Master 4 hardware ID used by that mouse and expects the standard Logi Options+ agent path. Other Logitech mice and other AltTab versions are not verified.

## Install manually

1. Install and start Logi Options+, Hammerspoon, and AltTab. In Logi Options+, assign the MX **thumb button to F13** and the **third side button to F14** as keystrokes.
2. Clone this repository, then build the helper:

   ```sh
   git clone https://github.com/aytekaksu/mx-master-mac.git
   cd mx-master-mac
   make
   ```

3. Copy the helper and Lua files:

   ```sh
   mkdir -p ~/.hammerspoon
   cp build/mx4-device-helper hammerspoon/mx4-safe-init.lua hammerspoon/mx4-helper-runtime.lua ~/.hammerspoon/
   ```

4. Add these lines **once** to `~/.hammerspoon/init.lua`. If the file already exists, keep its other lines. The sample [init.lua.example](hammerspoon/init.lua.example) is for a new Hammerspoon setup.

   ```lua
   dofile(hs.configdir .. "/mx4-safe-init.lua")
   dofile(hs.configdir .. "/mx4-helper-runtime.lua")
   ```

5. Grant the requested macOS permissions, then reload Hammerspoon and start AltTab. In AltTab settings, you can also assign **Command+Tab** if you want its window thumbnails from the keyboard. The mouse window layer uses AltTab whether or not you choose that keyboard shortcut.

Hold a button and try one wheel notch in each direction. If a permission is granted after an app is already running, quit and reopen that app before testing again.

## How it works

```text
MX Master 4 + Logi Options+ (F13/F14)
               ↓
Native helper: checks the mouse source and groups wheel steps
               ↓ tagged actions
Hammerspoon: browser tab/click shortcuts or AltTab commands
               ↓
Your browser or AltTab's window thumbnails
```

The helper consumes a wheel or click only when it recognizes the MX Master 4 action. Trackpad and unknown-device input pass through. Browser tabs do **not** need AltTab: Vivaldi uses its visible tab list through Accessibility and AppleScript; Safari, Chrome, Firefox, Brave, and Edge use their built-in shortcuts. Other apps get a Control+Tab fallback, which may not work everywhere.

The window wheel **does** need AltTab. Hammerspoon opens AltTab's thumbnails, moves the highlight, and asks AltTab to focus the selected window on button release. Reverse steps send Left Arrow only to AltTab, so no Command or Shift key is held globally while using the mouse. Without AltTab, the window wheel gesture will not switch windows.

## Pause and check

Quit Hammerspoon to stop the macros; reopen it to resume. In Hammerspoon's console, `mx4runtime.pause()` and `mx4runtime.resume()` also work. `mx4runtime.status()` reports whether the helper is running.

- No mouse actions: check the F13/F14 mappings and macOS permissions, then reload Hammerspoon.
- Tabs fail only in Vivaldi: allow Hammerspoon Accessibility and Vivaldi Automation.
- Windows fail: check that AltTab is running at `/Applications/AltTab.app`.
- Wheel actions fail with another Logitech mouse connected: the current helper accepts senderless Logi wheel events only when the MX Master 4 is the sole connected Logitech pointing device.

## Roadmap

1. Build a small native Mac app with a simple settings screen that installs and configures this existing stack for new users.
2. Move the Hammerspoon actions and native helper into that app, while keeping MX-only input filtering and configurable shortcuts.
3. Build an independent window switcher inside the app so AltTab is no longer required. The current project does not include AltTab's code.

These are plans, not features in this release. The current setup uses AltTab 11.6.1's internal `--qa-state` command and two nonpublic macOS HID functions, so macOS or AltTab updates may require changes.

## Contributing and license

Issues and pull requests are welcome. Changes to `main` require the repository owner's review; see [CONTRIBUTING.md](CONTRIBUTING.md). This project is [MIT licensed](LICENSE). Hammerspoon, AltTab, and Logi Options+ are separate dependencies with their own licenses. The helper's HID sender technique was informed by LinearMouse; see [third-party notices](THIRD_PARTY_NOTICES.md).
