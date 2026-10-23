#!/bin/zsh
#
# install.sh - put the built stats dylib into MetalHUDmenu.app.
#
# Not a plain cp. Overwriting a signed dylib in place while any process has it
# mapped leaves the mapping's pages no longer matching the signature, and the
# next process to insert it is killed on sight:
#
#   SIGKILL (Code Signature Invalid) ... CODESIGNING "Invalid Page"
#
# ...which reads exactly like a crash in the dylib's own code. Writing a new
# file and renaming it over gives a fresh inode, so existing mappings are
# untouched and the new one is signed from the start.

emulate -L zsh
APP=${1:-/Applications/MetalHUDmenu.app}
SRC=${0:A:h}/build/libMHUDStats.dylib
DST="$APP/Contents/Resources/libMHUDStats.dylib"

[[ -f $SRC ]] || { print -u2 -- "no build at $SRC -- run build.sh first"; exit 1 }
[[ -d $APP ]] || { print -u2 -- "no app at $APP"; exit 1 }

cp "$SRC" "$DST.new" || exit 1
codesign --force --sign - "$DST.new" >/dev/null 2>&1 || {
    print -u2 -- "could not sign the dylib"; rm -f "$DST.new"; exit 1 }
mv -f "$DST.new" "$DST" || exit 1
codesign --force --sign - "$APP" >/dev/null 2>&1
if codesign -v "$DST" >/dev/null 2>&1; then
    print -- "installed and verifies: $DST"
else
    print -u2 -- "installed but does NOT verify -- it will be killed on load"
    exit 1
fi
