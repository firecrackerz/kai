#!/bin/bash

# Must have swiftenv installed here. Default for homebrew
CC=`/usr/local/bin/swiftenv which swift`

#echo "Using $CC"
export SDKROOT=$(xcrun --show-sdk-path --sdk macosx)

SWIFTC_FLAGS="-DDebug"

$CC build -Xswiftc $SWIFTC_FLAGS

if [ $? -ne 0 ]; then

  exit 1
fi

cp .build/debug/kai $HOME/.dotfiles/bin/

