#!/bin/bash
# OS conditionals and C/ObjC bindings belong in files named Platform*.pas
# (and platform*.inc) only (bead od-31j.29). Program files may keep the
# standard `{$IFDEF UNIX} cthreads` uses line. There are no exemptions: any
# other file with OS-specific code fails.
set -u
# CHECK_PLATFORM_ROOT points the check at another tree for its own tests
# (tests/test_check_platform.sh).
cd "${CHECK_PLATFORM_ROOT:-$(dirname "$0")/..}"

# Matched case-insensitively (FPC directives are): {$IFDEF/IFNDEF OS},
# {$IF DEFINED(OS)}, per-OS include files, and binding directives
# (`external`, `cvar; external`, `objcclass external`) — not the plain word.
OS='(DARWIN|UNIX|WINDOWS|MSWINDOWS|LINUX|BSD|FREEBSD|MACOS|COCOA)'
PATTERN="\\{\\\$IF(N?DEF)? +$OS\\b|\\{\\\$(ELSE)?IF[^}]*DEFINED *\\( *$OS|\\{\\\$I(NCLUDE)? +[^}]*_(darwin|unix|windows|linux|other)|(;|\\)) *external\\b|^ *external\\b|\\bexternal *('|\"|name\\b|;)|objc(class|protocol|category) +external"
status=0
FILES=$(ls src/units/*.pas src/*.lpr src/gui/*.pas src/gui/*.lpr 2>/dev/null; find src -name '*.inc')
for f in $FILES; do
  # Only Platform units and their include files are exempt, not programs.
  case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in platform*.pas|platform*.inc) continue ;; esac
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
  if [[ -n "$hits" ]]; then
    echo "check-platform: OS-specific code outside Platform*.pas in $f:" >&2
    echo "$hits" | sed 's/^/  /' >&2
    status=1
  fi
done
[[ $status -eq 0 ]] && echo "check-platform: ok"
exit $status
