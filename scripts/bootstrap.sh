#!/bin/sh
set -eu

# This file is served from the matching versioned Git tag. Update the archive
# digest when packaging a new release; never execute an unchecked download.
version=v0.5.0
package_name="mx-master-mac-$version-macos-universal"
package_sha256=3262f2b7b5142cd4e1517665b1324398df06b2c4381394929c6de55028fef9f1
hammerspoon_sha256=11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa
alttab_sha256=0bb2f23b061636173b288b19f3f5412a8ad33f5ac6826a317f0ed28e7b64afe8
apps_dir=/Applications
logi_app="$apps_dir/logioptionsplus.app"
logi_agent='/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent'
app_stage=''
app_stage_sudo=0
logi_incomplete=0
openlogi_mount=''
provider=optionsplus
install_alttab=0

fail() {
    printf 'MX Master Mac: %s\n' "$*" >&2
    exit 1
}

download() {
    /usr/bin/curl --fail --silent --show-error --location --retry 3 \
        --proto '=https' --tlsv1.2 --output "$2" "$1"
}

check_sha256() {
    actual=$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')
    [ "$actual" = "$2" ] || fail "Checksum mismatch for $(basename "$1"); nothing has been installed."
}

check_team() {
    /usr/bin/codesign --verify --strict --deep "$1" || fail "Invalid app signature: $1"
    actual=$(/usr/bin/codesign -dv --verbose=2 "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
    [ "$actual" = "$2" ] || fail "Unexpected app publisher: $1"
}

copy_app_if_missing() {
    source_app=$1
    target_app="$apps_dir/$2"
    expected_team=$3
    if [ -e "$target_app" ] || [ -L "$target_app" ]; then
        [ -d "$target_app" ] || fail "Existing $target_app is not a working app; repair it before rerunning."
        check_team "$target_app" "$expected_team"
        printf 'Keeping existing %s\n' "$target_app"
        return
    fi
    printf 'Installing %s\n' "$target_app"
    if [ -w "$apps_dir" ]; then
        app_stage=$(/usr/bin/mktemp -d "$apps_dir/.mx-master-mac.XXXXXX")
        /usr/bin/ditto "$source_app" "$app_stage/$2"
    else
        app_stage=$(/usr/bin/sudo /usr/bin/mktemp -d "$apps_dir/.mx-master-mac.XXXXXX")
        app_stage_sudo=1
        /usr/bin/sudo /usr/bin/ditto "$source_app" "$app_stage/$2"
        /usr/bin/sudo /bin/chmod 755 "$app_stage"
    fi
    check_team "$app_stage/$2" "$expected_team"
    if [ "$app_stage_sudo" -eq 1 ]; then
        /usr/bin/sudo /bin/mv -n "$app_stage/$2" "$target_app"
    else
        /bin/mv -n "$app_stage/$2" "$target_app"
    fi
    check_team "$target_app" "$expected_team"
    cleanup_app_stage
}

cleanup_app_stage() {
    [ -n "$app_stage" ] || return 0
    if [ "$app_stage_sudo" -eq 1 ]; then
        /usr/bin/sudo -n /bin/rm -r "$app_stage" 2>/dev/null || true
    else
        /bin/rm -r "$app_stage" 2>/dev/null || true
    fi
    app_stage=''
    app_stage_sudo=0
}

cleanup() {
    cleanup_app_stage
    if [ -n "$openlogi_mount" ]; then
        /usr/bin/hdiutil detach "$openlogi_mount" -quiet || true
    fi
    /bin/rm -r "$work_dir"
}

[ "$(/usr/bin/id -u)" -ne 0 ] || fail 'Run this as your normal Mac user, without sudo.'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'This installer requires macOS.'
major_version=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)
case "$major_version" in
    ''|*[!0-9]*) fail 'Could not read your macOS version.' ;;
esac
[ "$major_version" -ge 13 ] || fail 'macOS 13 or newer is required.'

work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mx-master-mac.XXXXXX")
trap 'cleanup' 0
trap 'exit 1' 1 2 3 15

printf 'Downloading MX Master Mac %s…\n' "$version"
package_zip="$work_dir/$package_name.zip"
download "https://github.com/aytekaksu/mx-master-mac/releases/download/$version/$package_name.zip" "$package_zip"
check_sha256 "$package_zip" "$package_sha256"
/usr/bin/ditto -xk "$package_zip" "$work_dir"
package_dir="$work_dir/$package_name"
[ -f "$package_dir/install.sh" ] && [ -f "$package_dir/mx4-device-helper" ] || fail 'The release package is incomplete.'

if [ -e "$apps_dir/Hammerspoon.app" ] || [ -L "$apps_dir/Hammerspoon.app" ]; then
    [ -d "$apps_dir/Hammerspoon.app" ] || fail 'The existing Hammerspoon path is not an app; repair it before rerunning.'
    check_team "$apps_dir/Hammerspoon.app" VQCYSNZB89
else
    printf 'Downloading Hammerspoon 1.1.1…\n'
    download 'https://github.com/Hammerspoon/hammerspoon/releases/download/1.1.1/Hammerspoon-1.1.1.zip' "$work_dir/hammerspoon.zip"
    check_sha256 "$work_dir/hammerspoon.zip" "$hammerspoon_sha256"
    /bin/mkdir "$work_dir/hammerspoon"
    /usr/bin/ditto -xk "$work_dir/hammerspoon.zip" "$work_dir/hammerspoon"
    check_team "$work_dir/hammerspoon/Hammerspoon.app" VQCYSNZB89
fi

# Launch Services finds an existing copy even outside /Applications. This only
# looks up the app's path; it neither launches it nor changes its preferences.
alttab_path=$(/usr/bin/osascript -l JavaScript -e '
    ObjC.import("AppKit");
    var url = $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier("com.lwouis.alt-tab-macos");
    if (!url.isNil()) ObjC.unwrap(url.path);
' 2>/dev/null || true)
if [ -n "$alttab_path" ] && [ -d "$alttab_path" ]; then
    printf 'Keeping existing AltTab at %s.\n' "$alttab_path"
elif [ -e "$apps_dir/AltTab.app" ] || [ -L "$apps_dir/AltTab.app" ]; then
    printf 'Keeping the existing AltTab path. Repair that app to enable its optional window thumbnails.\n'
elif [ -t 0 ]; then
    printf '\nmacOS switches apps. Optional AltTab adds individual window thumbnails.\n'
    printf 'Install AltTab too? [y/N] '
    answer=''
    read -r answer || answer=''
    case "$answer" in y|Y|yes|YES|Yes) install_alttab=1 ;; esac
fi

if [ "$install_alttab" -eq 1 ]; then
    printf 'Downloading tested AltTab 11.6.1…\n'
    download 'https://github.com/lwouis/alt-tab-macos/releases/download/v11.6.1/AltTab-11.6.1.zip' "$work_dir/alttab.zip"
    check_sha256 "$work_dir/alttab.zip" "$alttab_sha256"
    /bin/mkdir "$work_dir/alttab"
    /usr/bin/ditto -xk "$work_dir/alttab.zip" "$work_dir/alttab"
    check_team "$work_dir/alttab/AltTab.app" QXD7GW8FHY
fi

# Prefer an existing OpenLogi; preserve an existing Options+ installation.
# Never install a second HID++ provider automatically beside the first one.
openlogi_path=$(/usr/bin/osascript -l JavaScript -e '
    ObjC.import("AppKit");
    var url = $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier("org.openlogi.openlogi");
    if (!url.isNil()) ObjC.unwrap(url.path);
' 2>/dev/null || true)
if [ -z "$openlogi_path" ] && { [ -e "$apps_dir/OpenLogi.app" ] || [ -L "$apps_dir/OpenLogi.app" ]; }; then
    openlogi_path="$apps_dir/OpenLogi.app"
fi
if [ -n "$openlogi_path" ]; then
    [ -d "$openlogi_path" ] || fail 'The existing OpenLogi path is not an app; repair it before rerunning.'
    check_team "$openlogi_path" 8U3ZJ258K9
    provider=openlogi
    printf 'Keeping existing OpenLogi at %s. Use version 0.8.8 or newer.\n' "$openlogi_path"
    if [ -e "$logi_app" ] || [ -e "$logi_agent" ]; then
        printf 'Both providers are installed. Quit Options+ and stop its background agent before using OpenLogi.\n'
    fi
elif [ -e "$logi_app" ] || [ -L "$logi_app" ] || [ -e "$logi_agent" ] || [ -L "$logi_agent" ]; then
    if [ -e "$logi_app" ] || [ -L "$logi_app" ]; then
        [ -d "$logi_app" ] || fail 'The existing Logi Options+ path is not an app; repair it before rerunning.'
        check_team "$logi_app" QED4VVPZWA
    fi
    if [ ! -d "$logi_app" ] || [ ! -x "$logi_agent" ]; then
        logi_incomplete=1
    fi
else
    provider=openlogi
    case "$(/usr/bin/uname -m)" in
        arm64)
            openlogi_arch=arm64
            openlogi_sha256=be8a89bf36712d0a20db3c4df2b20ecfebbc1a44d9242fcc4d42ebaa4fdb9495 ;;
        x86_64)
            openlogi_arch=x86_64
            openlogi_sha256=28a1bea803c55720818deddb1d151a058e9ca36fa01b603e532cdacacbf7b991 ;;
        *) fail 'OpenLogi requires an Apple Silicon or Intel Mac.' ;;
    esac
    printf 'Downloading OpenLogi 0.8.8 (%s)…\n' "$openlogi_arch"
    download "https://github.com/AprilNEA/OpenLogi/releases/download/v0.8.8/OpenLogi-v0.8.8-macos-$openlogi_arch.dmg" "$work_dir/openlogi.dmg"
    check_sha256 "$work_dir/openlogi.dmg" "$openlogi_sha256"
    /bin/mkdir "$work_dir/openlogi-mount"
    /usr/bin/hdiutil attach -readonly -nobrowse -quiet -mountpoint "$work_dir/openlogi-mount" "$work_dir/openlogi.dmg"
    openlogi_mount="$work_dir/openlogi-mount"
    check_team "$openlogi_mount/OpenLogi.app" 8U3ZJ258K9
    /usr/sbin/spctl --assess --type execute "$openlogi_mount/OpenLogi.app" || fail 'macOS did not approve OpenLogi.'
fi

if [ -d "$work_dir/hammerspoon/Hammerspoon.app" ]; then
    copy_app_if_missing "$work_dir/hammerspoon/Hammerspoon.app" Hammerspoon.app VQCYSNZB89
else
    printf 'Keeping existing Hammerspoon.\n'
fi
if [ -d "$work_dir/alttab/AltTab.app" ]; then
    copy_app_if_missing "$work_dir/alttab/AltTab.app" AltTab.app QXD7GW8FHY
else
    printf 'AltTab is optional; no AltTab download was installed.\n'
fi

if [ -n "$openlogi_mount" ]; then
    copy_app_if_missing "$openlogi_mount/OpenLogi.app" OpenLogi.app 8U3ZJ258K9
elif [ "$provider" = optionsplus ]; then
    printf 'Keeping existing Logi Options+.\n'
fi

/bin/sh "$package_dir/install.sh"

printf '\nMX Master Mac files are installed. Finish these setup steps:\n'
if [ "$provider" = openlogi ]; then
    printf '• Open OpenLogi and grant OpenLogi Agent Accessibility and Input Monitoring.\n'
    printf '• Follow the OpenLogi setup guide to assign held F13/F14 and preserve raw wheel events:\n'
    printf '  https://github.com/aytekaksu/mx-master-mac/blob/%s/docs/openlogi.md\n' "$version"
else
    printf '• In Logi Options+, set the MX thumb button to F13 and the third side button to F14.\n'
fi
printf '• Grant the macOS permissions requested by Hammerspoon and the helper.\n'
printf '• Start Hammerspoon, or reload it if it was already running.\n'
printf '• If using AltTab, start it and grant its Accessibility and Screen Recording permissions.\n'
printf '• The window wheel detects a running AltTab. Quit AltTab to use the macOS app switcher.\n'
if [ "$provider" = optionsplus ] && [ ! -x "$logi_agent" ]; then
    printf 'Logi Options+ is not ready yet. Restart, then check its installation if needed.\n'
fi
printf 'Apps were not launched or reloaded by this script.\n'
if [ "$logi_incomplete" -eq 1 ]; then
    fail 'Existing Logi Options+ is incomplete. The MX files were installed; restart or repair Logi Options+ before using them.'
fi
