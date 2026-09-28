#!/bin/sh
# Builds a release into app/build/release: the universal, ad-hoc signed app as HermesContext.zip, and
# install.sh stamped with this version and commit, which must already be on origin/main. Publishing them
# as a GitHub Release is a separate step.
set -eu
cd "$(dirname "$0")"
if [ -n "$(git status --porcelain -- hermes_context_observer app/Sources app/Package.swift app/bundle.sh install.sh pyproject.toml)" ]; then
    echo "release.sh: commit the app, plugin and installer first; install.sh pins the commit." >&2
    exit 1
fi
git fetch --quiet origin main
git merge-base --is-ancestor HEAD origin/main || { echo "release.sh: push to origin/main first; install.sh pins the commit." >&2; exit 1; }
plugin_version=$(sed -n 's/^version: "\(.*\)"$/\1/p' hermes_context_observer/plugin.yaml)
out=build/release
rm -rf "app/$out"
UNIVERSAL=1 OUT=$out app/bundle.sh >/dev/null
version=$(plutil -extract CFBundleShortVersionString raw "app/$out/HermesContext.app/Contents/Info.plist")
[ "$version" = "$plugin_version" ] || { echo "release.sh: app $version but plugin $plugin_version." >&2; exit 1; }
commit=$(git rev-parse HEAD)
ditto -c -k --keepParent "app/$out/HermesContext.app" "app/$out/HermesContext.zip"
sed -e "s/@VERSION@/$version/" -e "s/@COMMIT@/$commit/" install.sh >"app/$out/install.sh"
echo "app/$out: HermesContext.zip and install.sh for v$version at $commit"
