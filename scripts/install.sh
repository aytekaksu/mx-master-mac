#!/bin/sh
set -eu

if [ "$(id -u)" -eq 0 ]; then
    printf 'Run this as your normal Mac user, without sudo.\n' >&2
    exit 1
fi

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
target_dir=${MX4_HAMMERSPOON_DIR:-"$HOME/.hammerspoon"}
for file in mx4-device-helper mx4-safe-init.lua mx4-helper-runtime.lua; do
    if [ ! -f "$package_dir/$file" ]; then
        printf 'Missing release file: %s\n' "$file" >&2
        exit 1
    fi
done

if ! codesign --verify --strict "$package_dir/mx4-device-helper"; then
    printf 'Helper signature check failed; nothing was installed.\n' >&2
    exit 1
fi

for file in mx4-device-helper mx4-safe-init.lua mx4-helper-runtime.lua init.lua; do
    if [ -L "$target_dir/$file" ]; then
        printf '%s is a symlink. Add the loader lines manually; no files were changed.\n' "$target_dir/$file" >&2
        exit 1
    fi
done
if [ -e "$target_dir/init.lua" ] && { [ ! -f "$target_dir/init.lua" ] || [ ! -w "$target_dir/init.lua" ]; }; then
    printf '%s must be a writable file; no files were changed.\n' "$target_dir/init.lua" >&2
    exit 1
fi

mkdir -p "$target_dir"
stage_dir=$(mktemp -d "$target_dir/mx4-install.XXXXXX")
trap 'rm -r "$stage_dir" 2>/dev/null || true' 0 HUP INT TERM
cp "$package_dir/mx4-device-helper" "$stage_dir/mx4-device-helper"
cp "$package_dir/mx4-safe-init.lua" "$stage_dir/mx4-safe-init.lua"
cp "$package_dir/mx4-helper-runtime.lua" "$stage_dir/mx4-helper-runtime.lua"
chmod 755 "$stage_dir/mx4-device-helper"
codesign --verify --strict "$stage_dir/mx4-device-helper"

backup_dir=''
for file in mx4-device-helper mx4-safe-init.lua mx4-helper-runtime.lua init.lua; do
    if [ -e "$target_dir/$file" ]; then
        if [ -z "$backup_dir" ]; then
            backup_dir=$(mktemp -d "$target_dir/mx4-backup.XXXXXX")
        fi
        cp -p "$target_dir/$file" "$backup_dir/$file"
    fi
done

for file in mx4-device-helper mx4-safe-init.lua mx4-helper-runtime.lua; do
    mv -f "$stage_dir/$file" "$target_dir/$file"
done
rmdir "$stage_dir"
trap - 0 HUP INT TERM

init_file="$target_dir/init.lua"
touch "$init_file"
receiver_line='dofile(hs.configdir .. "/mx4-safe-init.lua")'
runtime_line='dofile(hs.configdir .. "/mx4-helper-runtime.lua")'
if ! grep -Fqx "$receiver_line" "$init_file"; then
    printf '\n%s\n' "$receiver_line" >> "$init_file"
fi
if ! grep -Fqx "$runtime_line" "$init_file"; then
    printf '%s\n' "$runtime_line" >> "$init_file"
fi

if [ -n "$backup_dir" ]; then
    printf 'Previous files were saved in %s\n' "$backup_dir"
fi
printf 'Installed to %s. Grant macOS permissions, then reload Hammerspoon when ready.\n' "$target_dir"
if xattr -p com.apple.quarantine "$target_dir/mx4-device-helper" >/dev/null 2>&1; then
    printf 'macOS marked the helper as a download. It may require approval in System Settings > Privacy & Security.\n'
fi
