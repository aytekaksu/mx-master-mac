#!/bin/sh
set -eu

version=${1:-v0.5.0}
if ! printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf 'Expected a version such as v0.5.0\n' >&2
    exit 2
fi

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
package_name="mx-master-mac-$version-macos-universal"
dist_dir="$repo_dir/dist"
package_dir="$dist_dir/$package_name"
archive="$dist_dir/$package_name.zip"

if [ -e "$package_dir" ] || [ -e "$archive" ]; then
    printf 'Release output already exists: %s\n' "$package_name" >&2
    exit 1
fi

codesign --verify --strict "$repo_dir/build/mx4-device-helper"
mkdir -p "$package_dir"
cp "$repo_dir/build/mx4-device-helper" "$package_dir/mx4-device-helper"
cp "$repo_dir/hammerspoon/mx4-safe-init.lua" "$package_dir/mx4-safe-init.lua"
cp "$repo_dir/hammerspoon/mx4-helper-runtime.lua" "$package_dir/mx4-helper-runtime.lua"
cp "$repo_dir/scripts/install.sh" "$package_dir/install.sh"
cp "$repo_dir/README.md" "$package_dir/README.md"
mkdir -p "$package_dir/docs"
cp "$repo_dir/docs/openlogi.md" "$package_dir/docs/openlogi.md"
cp "$repo_dir/LICENSE" "$package_dir/LICENSE"
cp "$repo_dir/THIRD_PARTY_NOTICES.md" "$package_dir/THIRD_PARTY_NOTICES.md"
chmod 755 "$package_dir/mx4-device-helper" "$package_dir/install.sh"
ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent "$package_dir" "$archive"
(cd "$dist_dir" && shasum -a 256 "$package_name.zip" > "$package_name.zip.sha256")
printf 'Created %s\n' "$archive"
