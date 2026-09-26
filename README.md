<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="MX Master Mac — an MX Master inside an Apple Magic Trackpad" width="176" height="176">
  </picture>
</p>

# MX Master Mac

**The way to use your MX Master 4 on a Mac—without missing the trackpad.**

Switch browser tabs and windows, and use everyday shortcuts, right from your mouse. Hold a side button and use the wheel or clicks; release it to use the mouse normally again. The helper identifies MX input so your trackpad keeps working. One Terminal command downloads the compiled helper and installs missing companion apps. There is no Hammerspoon pop-up UI.

## Controls

| Hold | MX wheel up / down | MX left / right click |
| --- | --- | --- |
| Thumb button | Next / previous browser tab | Close / new tab |
| Third side button | Previous / next app, or window with AltTab; select on release | Copy / paste |

While holding the third side button, click **left and right together** to select all. Click shortcuts use the usual macOS Command shortcuts in the active app.

## Requirements

- MX Master 4 and macOS 13 or newer, plus [Hammerspoon](https://www.hammerspoon.org/) and either [OpenLogi](https://github.com/AprilNEA/OpenLogi) **0.8.8+** or [Logi Options+](https://www.logitech.com/software/logi-options-plus.html). The installer keeps an existing provider and installs **OpenLogi by default** when neither is present. An administrator password may be needed to install apps in `/Applications`. Run only one mouse provider at a time.
- **AltTab is optional.** Apple's built-in switcher works without it. The installer can also download [AltTab](https://alt-tab.app/) if you choose individual window thumbnails. Existing apps keep their versions and settings.
- macOS Accessibility and Input Monitoring permissions for the helper and Hammerspoon. AltTab additionally needs Accessibility and Screen Recording when used. macOS may ask for Automation permission when switching Vivaldi tabs.

The prebuilt helper contains Apple Silicon and Intel code and targets macOS 13 or newer. Mouse behavior has been tested on one Apple Silicon Mac running macOS 26.3.1 with native app switching and AltTab 11.6.1 / 11.7.1; the Intel helper tests passed under Rosetta, but a physical Intel Mac and older macOS versions have not been tested. The helper currently recognizes the MX Master 4 hardware ID used by that mouse and accepts the standard Logi Options+ agent path or the signed OpenLogi background agent. OpenLogi needs raw wheel input: keep smooth scrolling off and vertical sensitivity at 14 (1×). Other Logitech mice and other AltTab versions are not verified.

## Install with one command

Paste this into Terminal as your normal Mac user:

```sh
(s=$(curl -fsSL https://github.com/aytekaksu/mx-master-mac/raw/v0.5.0/scripts/bootstrap.sh)&&[ "$s" ]&&sh -c "$s")
```

The script downloads this release, checks its built-in SHA-256 digest, and installs the helper in `~/.hammerspoon`. It installs missing Hammerspoon 1.1.1 from its verified official release, and the official OpenLogi 0.8.8 release for Apple Silicon or Intel after checking its SHA-256 digest, Developer ID signature, and macOS approval. Existing Logi Options+ installs are supported and preserved. If AltTab is missing, it asks **“Install AltTab too? [y/N]”**: press Return to use macOS, or type `y` to install the tested AltTab 11.6.1. With no interactive terminal, it defaults to macOS.

No Homebrew, Xcode tools, manual unzip, or source build is needed. The script backs up existing Hammerspoon files, keeps installed apps, and does not launch or reload them. You can run the command again after an interrupted install.

After the command finishes:

1. **OpenLogi:** follow the short [OpenLogi setup guide](docs/openlogi.md) to grant the Agent permissions and assign held F13/F14 shortcuts in its configuration file. **Options+:** assign the MX **thumb button to F13** and the **third side button to F14** as keystrokes.
2. Grant the requested macOS permissions, then start Hammerspoon or reload it if already running. To use AltTab's thumbnails, start AltTab too and grant its permissions. Detection happens automatically; its keyboard shortcuts stay as you set them.
3. Hold a button and try one wheel notch in each direction. If you granted a permission after an app started, quit and reopen that app before testing again.

The helper is ad hoc signed, not Developer ID signed or notarized. macOS may ask you to approve this specific download in **System Settings → Privacy & Security** before it can run. The release also provides a `.sha256` checksum file for the ZIP. Do not disable Gatekeeper system-wide.

### Manual download (optional)

Download **`mx-master-mac-v0.5.0-macos-universal.zip`** from the [latest GitHub release](https://github.com/aytekaksu/mx-master-mac/releases/latest), unzip it, and run `sh install.sh` in the unzipped folder. Install Hammerspoon and either OpenLogi or Logi Options+ yourself; add AltTab if you want its thumbnails. GitHub's automatic “Source code” ZIP does not contain the compiled helper.

### Build from source (optional)

If you prefer to build the helper yourself, install Xcode Command Line Tools, clone this repository, then run `make` and `make test`. The resulting universal helper is `build/mx4-device-helper`; copy it and the two Lua files from `hammerspoon/` into `~/.hammerspoon/`, then add the loader lines from [init.lua.example](hammerspoon/init.lua.example) to your Hammerspoon config.

## How it works

```text
MX Master 4 + OpenLogi or Options+ (held F13/F14)
               ↓
Native helper: checks the mouse source and groups wheel steps
               ↓ tagged actions
Hammerspoon: browser shortcuts + automatic switcher detection
               ↓
Your browser, Apple's app icons, or AltTab's window thumbnails
```

The helper consumes a wheel or click only when it recognizes the MX Master 4 action. Trackpad and unknown-device input pass through. Browser tabs do **not** need AltTab: Vivaldi uses its visible tab list through Accessibility and AppleScript; Safari, Chrome, Firefox, Brave, and Edge use their built-in shortcuts. Other apps get a Control+Tab fallback, which may not work everywhere.

### Which switcher will I see?

| What's running | Third-button wheel behavior |
| --- | --- |
| No AltTab | Apple's Command+Tab app icons. One step moves to the next or previous **app**. |
| AltTab | AltTab's thumbnails. One step moves to the next or previous **window**, including windows from the same app. |

Release the mouse button to select the highlighted item. [Apple's standard switcher groups by app](https://support.apple.com/guide/mac-help/switch-between-open-apps-mchlp2469/mac); AltTab provides individual windows. Start or quit AltTab to change modes, with no Hammerspoon reload. A running AltTab copy is detected even outside `/Applications`.

Trackpad scrolling or an ordinary mouse click cancels a mouse-opened native preview and passes through unchanged. Release the third button before starting another selection. A switcher opened from the keyboard keeps its normal behavior.

For macOS, Hammerspoon opens the native switcher and uses Accessibility to select, confirm, and cancel its app icons. It never presses and holds a modifier key. For AltTab, it uses its CLI and sends reverse navigation only to AltTab. Neither mode draws a Hammerspoon overlay or changes your keyboard shortcuts.

## Pause and check

Quit Hammerspoon to stop the macros; reopen it to resume. In Hammerspoon's console, `mx4runtime.pause()` and `mx4runtime.resume()` also work. `mx4runtime.status()` reports whether the helper is running. After a wheel gesture, `mx4.status()` reports `windowBackend` (`macos` or `alttab`) and any `switcherError`.

- No mouse actions: check the F13/F14 mappings and macOS permissions, then reload Hammerspoon.
- Tabs fail only in Vivaldi: allow Hammerspoon Accessibility and Vivaldi Automation.
- Native app switching fails: check Hammerspoon's Accessibility permission and that Command+Tab opens Apple's switcher. Other apps that replace Command+Tab may conflict.
- AltTab switching fails: check its permissions and version. If its CLI is incompatible or unavailable, update or quit AltTab to use macOS. We leave a running AltTab's shortcuts alone instead of sending keystrokes into a conflicting switcher.
- Wheel actions fail with another Logitech mouse connected: the current helper accepts senderless Logi wheel events only when the MX Master 4 is the sole connected Logitech pointing device.

## Roadmap

1. Build a small native Mac app with a simple settings screen that installs and configures this existing stack for new users, including OpenLogi button setup without editing a file.
2. Move the Hammerspoon actions and native helper into that app, while keeping MX-only input filtering and configurable shortcuts.
3. Add individual window thumbnails inside the app, alongside native app switching, so that feature also works without AltTab. The current project does not include AltTab's code.

These are plans, not features in this release. The current setup uses AltTab's internal `--qa-state` command when AltTab is running, plus two nonpublic macOS HID functions in the helper. macOS or AltTab updates may require changes.

## Contributing and license

Issues and pull requests are welcome. Changes to `main` require the repository owner's review; see [CONTRIBUTING.md](CONTRIBUTING.md). The code is [MIT licensed](LICENSE); logo artwork has [separate attribution notices](assets/README.md). Hammerspoon, AltTab, OpenLogi, and Logi Options+ are separate dependencies with their own licenses. The helper's HID sender technique was informed by LinearMouse; see [third-party notices](THIRD_PARTY_NOTICES.md).

## Logo

[Logo files and artwork credits](assets/README.md).
