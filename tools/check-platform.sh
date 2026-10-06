#!/bin/bash
# OS conditionals and C bindings belong in src/units/Platform*.pas (and their
# .inc files) only (bead od-31j.29). Program files may keep the standard
# `{$IFDEF UNIX} cthreads` uses line. BASELINE lists files not yet migrated;
# remove an entry once its unit is clean, and the script fails if a listed
# file is already clean so the list cannot go stale.
set -u
# CHECK_PLATFORM_ROOT / CHECK_PLATFORM_BASELINE override both for the
# script's own tests (tests/test_check_platform.sh).
cd "${CHECK_PLATFORM_ROOT:-$(dirname "$0")/..}"

BASELINE="
src/units/DirReader.pas
src/units/FSEventsJournal.pas
"
BASELINE="${CHECK_PLATFORM_BASELINE-$BASELINE}"

# Matched case-insensitively (FPC directives are): {$IFDEF/IFNDEF OS},
# {$IF DEFINED(OS)}, per-OS include files, and binding directives
# (`external`, `cvar; external`, `objcclass external`) — not the plain word.
OS='(DARWIN|UNIX|WINDOWS|MSWINDOWS|LINUX|BSD|FREEBSD|MACOS|COCOA)'
PATTERN="\\{\\\$IF(N?DEF)? +$OS\\b|\\{\\\$(ELSE)?IF[^}]*DEFINED *\\( *$OS|\\{\\\$I(NCLUDE)? +[^}]*_(darwin|unix|windows|linux|other)|(;|\\)) *external\\b|^ *external\\b|\\bexternal *('|\"|name\\b|;)|objc(class|protocol|category) +external"
status=0
FILES=$(ls src/units/*.pas src/*.lpr src/gui/*.pas src/gui/*.lpr 2>/dev/null; find src -name '*.inc')
for f in $FILES; do
  case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in platform*) continue ;; esac
  hits=$(grep -niE "$PATTERN" "$f" || true)
  # A lone {$IFDEF UNIX} guarding only `cthreads,` is allowed in programs.
  if [[ "$f" == *.lpr ]]; then
    hits=$(echo "$hits" | grep -vE '^$' | while IFS=: read -r n rest; do
      next=$(sed -n "$((n + 1))p" "$f")
      shopt -s nocasematch
      [[ "$rest" =~ ^\ *\{\$IFDEF\ UNIX\}\ *$ && "$next" =~ ^\ *cthreads,?\ *$ ]] || echo "$n:$rest"
    done)
  fi
  hits=$(echo "$hits" | grep -vE '^$' || true)
  listed=0
  echo "$BASELINE" | grep -qx "$f" && listed=1
  if [[ -n "$hits" && $listed -eq 0 ]]; then
    echo "check-platform: OS-specific code outside Platform*.pas in $f:" >&2
    echo "$hits" | sed 's/^/  /' >&2
    status=1
  elif [[ -z "$hits" && $listed -eq 1 ]]; then
    echo "check-platform: $f is clean; remove it from BASELINE" >&2
    status=1
  fi
done
pending=$(echo "$BASELINE" | grep -cvE '^$')
[[ $status -eq 0 ]] && echo "check-platform: ok ($pending file(s) still in baseline)"
exit $status
