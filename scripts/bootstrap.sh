#!/bin/sh
set -eu

# This file is served from the matching versioned Git tag. Update the archive
# digest when packaging a new release; never execute an unchecked download.
version=v0.3.0
package_name="mx-master-mac-$version-macos-universal"
package_sha256=95c78724277ca9802721172cfef6f9926276e86e177e839d0e8c116d4d8ad990
hammerspoon_sha256=11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa
alttab_sha256=0bb2f23b061636173b288b19f3f5412a8ad33f5ac6826a317f0ed28e7b64afe8
apps_dir=/Applications
logi_app="$apps_dir/logioptionsplus.app"
logi_agent='/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent'
app_stage=''
app_stage_sudo=0
logi_incomplete=0

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
    /usr/bin/mkdir "$work_dir/hammerspoon"
    /usr/bin/ditto -xk "$work_dir/hammerspoon.zip" "$work_dir/hammerspoon"
    check_team "$work_dir/hammerspoon/Hammerspoon.app" VQCYSNZB89
fi

if [ -e "$apps_dir/AltTab.app" ] || [ -L "$apps_dir/AltTab.app" ]; then
    [ -d "$apps_dir/AltTab.app" ] || fail 'The existing AltTab path is not an app; repair it before rerunning.'
    check_team "$apps_dir/AltTab.app" QXD7GW8FHY
else
    printf 'Downloading tested AltTab 11.6.1…\n'
    download 'https://github.com/lwouis/alt-tab-macos/releases/download/v11.6.1/AltTab-11.6.1.zip' "$work_dir/alttab.zip"
    check_sha256 "$work_dir/alttab.zip" "$alttab_sha256"
    /usr/bin/mkdir "$work_dir/alttab"
    /usr/bin/ditto -xk "$work_dir/alttab.zip" "$work_dir/alttab"
    check_team "$work_dir/alttab/AltTab.app" QXD7GW8FHY
fi

if [ -e "$logi_app" ] || [ -L "$logi_app" ] || [ -e "$logi_agent" ] || [ -L "$logi_agent" ]; then
    if [ -e "$logi_app" ] || [ -L "$logi_app" ]; then
        [ -d "$logi_app" ] || fail 'The existing Logi Options+ path is not an app; repair it before rerunning.'
        check_team "$logi_app" QED4VVPZWA
    fi
    if [ ! -d "$logi_app" ] || [ ! -x "$logi_agent" ]; then
        logi_incomplete=1
    fi
else
    printf 'Downloading Logi Options+ from Logitech…\n'
    download 'https://download01.logi.com/web/ftp/pub/techsupport/optionsplus/logioptionsplus_installer.zip' "$work_dir/logioptionsplus.zip"
    /usr/bin/mkdir "$work_dir/logi"
    /usr/bin/ditto -xk "$work_dir/logioptionsplus.zip" "$work_dir/logi"
    logi_installer="$work_dir/logi/logioptionsplus_installer.app"
    if [ ! -d "$logi_installer" ]; then
        logi_installer="$work_dir/logi/Logi Options+ Installer.app"
    fi
    [ -d "$logi_installer" ] || fail 'Logitech changed its installer layout; no apps were installed.'
    check_team "$logi_installer" QED4VVPZWA
    /usr/sbin/spctl --assess --type execute "$logi_installer" || fail 'macOS did not approve the Logitech installer.'
fi

if [ -d "$work_dir/hammerspoon/Hammerspoon.app" ]; then
    copy_app_if_missing "$work_dir/hammerspoon/Hammerspoon.app" Hammerspoon.app VQCYSNZB89
else
    printf 'Keeping existing Hammerspoon.\n'
fi
if [ -d "$work_dir/alttab/AltTab.app" ]; then
    copy_app_if_missing "$work_dir/alttab/AltTab.app" AltTab.app QXD7GW8FHY
else
    printf 'Keeping existing AltTab.\n'
fi

installed_logi=0
if [ -n "${logi_installer:-}" ]; then
    printf 'Installing Logi Options+ (macOS may ask for an administrator password)…\n'
    /usr/bin/sudo "$logi_installer/Contents/MacOS/logioptionsplus_installer" --quiet
    installed_logi=1
else
    printf 'Keeping existing Logi Options+.\n'
fi

/bin/sh "$package_dir/install.sh"

printf '\nMX Master Mac files are installed. Finish these setup steps:\n'
if [ "$installed_logi" -eq 1 ]; then
    printf '• Restart your Mac so the new Logi Options+ installation can finish.\n'
fi
printf '• In Logi Options+, set the MX thumb button to F13 and the third side button to F14.\n'
printf '• Grant the macOS permissions requested by Logi Options+, Hammerspoon, AltTab, and the helper.\n'
printf '• Start AltTab and Hammerspoon, or reload Hammerspoon if it was already running.\n'
if [ ! -x "$logi_agent" ]; then
    printf 'Logi Options+ is not ready yet. Restart, then check its installation if needed.\n'
fi
alttab_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$apps_dir/AltTab.app/Contents/Info.plist" 2>/dev/null || true)
if [ -n "$alttab_version" ] && [ "$alttab_version" != 11.6.1 ]; then
    printf 'Your existing AltTab %s was kept. The mouse window layer was tested with 11.6.1.\n' "$alttab_version"
fi
printf 'Hammerspoon and AltTab were not launched or reloaded by this script.\n'
if [ "$logi_incomplete" -eq 1 ]; then
    fail 'Existing Logi Options+ is incomplete. The MX files were installed; restart or repair Logi Options+ before using them.'
fi
