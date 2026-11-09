#!/bin/bash
# Helpers for comparing the installed app's designated signing requirement.
# This file is sourced by bundle.sh and its lightweight shell tests.

heard_requirement_matches() {
    local source="$1" target="$2" details requirement
    details=$(codesign -dr - "$source" 2>&1) || return 1
    case "$details" in
        *'designated => '*) requirement=${details#*designated => } ;;
        *) return 1 ;;
    esac
    # Do not print requirements: they can contain identifying information.
    codesign --verify -R="$requirement" "$target" >/dev/null 2>&1
}

heard_signing_compatible() {
    local installed="$1" candidate="$2"
    # Require both directions so an unusually broad requirement cannot silently
    # accept a replacement whose own identity would reject the installed app.
    heard_requirement_matches "$installed" "$candidate" &&
        heard_requirement_matches "$candidate" "$installed"
}
