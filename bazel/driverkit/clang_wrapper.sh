#!/bin/bash
# Wrapper script to strip -fprofile-instr-generate from linker command

args=()
for arg in "$@"; do
    if [[ "$arg" != "-fprofile-instr-generate" ]]; then
        args+=("$arg")
    fi
done

exec /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ "${args[@]}"
