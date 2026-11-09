#!/bin/bash
set -euo pipefail

# Pure shell tests; no app, keychain, TCC, or installed bundle is modified.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/bundle-safety.sh"

mode=compatible
codesign() {
    if [[ "$1" == "-dr" ]]; then
        case "$mode" in
            unreadable) return 1 ;;
            malformed) printf '%s\n' 'missing designated requirement' ;;
            *) printf '%s\n' 'designated => test-requirement' ;;
        esac
    elif [[ "$1" == "--verify" ]]; then
        [[ "$2" == '-R=test-requirement' ]] || return 1
        if [[ "$mode" == 'asymmetric' ]]; then [[ "$3" == 'candidate.app' ]]; return; fi
        [[ "$mode" == 'compatible' && ( "$3" == 'candidate.app' || "$3" == 'installed.app' ) ]]
    else
        return 1
    fi
}

heard_signing_compatible installed.app candidate.app || { printf 'compatible signer rejected\n' >&2; exit 1; }
mode=mismatch
if heard_signing_compatible installed.app candidate.app; then printf 'mismatched signer accepted\n' >&2; exit 1; fi
mode=asymmetric
if heard_signing_compatible installed.app candidate.app; then printf 'one-way signer match accepted\n' >&2; exit 1; fi
mode=unreadable
if heard_signing_compatible installed.app candidate.app; then printf 'unreadable signature accepted\n' >&2; exit 1; fi
mode=malformed
if heard_signing_compatible installed.app candidate.app; then printf 'malformed requirement accepted\n' >&2; exit 1; fi
printf 'Bundle signing compatibility tests passed (5 cases).\n'
