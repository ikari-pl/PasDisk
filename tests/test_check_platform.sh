#!/bin/bash
# Negative tests for tools/check-platform.sh: each case plants one kind of
# OS-specific code outside Platform* and expects the check to fail.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$HERE/tools/check-platform.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0

setup() {
  rm -rf "$T/src"
  mkdir -p "$T/src/units" "$T/src/gui"
  printf 'unit Clean;\ninterface\nimplementation\nend.\n' > "$T/src/units/Clean.pas"
  printf 'program p;\nuses\n  {$IFDEF UNIX}\n  cthreads,\n  {$ENDIF}\n  Clean;\nbegin\nend.\n' > "$T/src/p.lpr"
  printf 'unit PlatformX;\n{$IFDEF DARWIN}\nfunction f: Integer; cdecl; external '"'"'c'"'"';\n{$ENDIF}\nend.\n' > "$T/src/units/PlatformX.pas"
}

expect() { # expect <ok|fail> <name>
  if CHECK_PLATFORM_ROOT="$T" "$CHECK" >/dev/null 2>&1; then got=ok; else got=fail; fi
  if [[ "$got" == "$1" ]]; then echo "ok: $2"; else echo "FAIL: $2 (expected $1, got $got)"; fail=1; fi
}

setup; expect ok 'clean tree, Platform* bindings and cthreads guard are allowed'
setup; printf '{$IFDEF DARWIN}\n{$ENDIF}\n' >> "$T/src/units/Clean.pas"; expect fail '{$IFDEF DARWIN}'
setup; printf '{$ifdef darwin}\n{$endif}\n' >> "$T/src/units/Clean.pas"; expect fail 'lowercase {$ifdef darwin}'
setup; printf '{$IF DEFINED(UNIX)}\n{$ENDIF}\n' >> "$T/src/units/Clean.pas"; expect fail '{$IF DEFINED(UNIX)}'
setup; printf '{$if defined(windows) or defined(linux)}\n{$endif}\n' >> "$T/src/units/Clean.pas"; expect fail '{$if defined(...)} lowercase'
setup; printf 'var X: Pointer; cvar; external;\n' >> "$T/src/units/Clean.pas"; expect fail 'cvar; external'
setup; printf 'procedure g; external name '"'"'g'"'"';\n' >> "$T/src/units/Clean.pas"; expect fail 'external name'
setup; printf 'NSFoo = objcclass external (NSObject)\nend;\n' >> "$T/src/gui/Form.pas"; expect fail 'objcclass external in GUI unit'
setup; printf 'program g;\n{$IFDEF DARWIN}\n{$ENDIF}\nbegin\nend.\n' > "$T/src/gui/g.lpr"; expect fail 'GUI program file'
setup; printf '{$IFDEF UNIX}\n{$ENDIF}\n' > "$T/src/units/x.inc"; expect fail 'non-Platform .inc file'
setup; printf '{$I clean_darwin.inc}\n' >> "$T/src/units/Clean.pas"; expect fail 'per-OS include outside Platform*'
setup; printf '{ talks to external volumes }\n' >> "$T/src/units/Clean.pas"; expect ok 'the word "external" in a comment is allowed'
setup; printf '{$IFDEF UNIX}\n{$ENDIF}\n' > "$T/src/units/platformy_unix.inc"; expect ok 'Platform* .inc file is allowed'
setup; printf 'program PlatformFoo;\n{$IFDEF DARWIN}\n{$ENDIF}\nbegin\nend.\n' > "$T/src/PlatformFoo.lpr"; expect fail 'a program named Platform* is not exempt'
setup; printf 'program PlatformGui;\n{$IFDEF DARWIN}\n{$ENDIF}\nbegin\nend.\n' > "$T/src/gui/PlatformGui.lpr"; expect fail 'a GUI program named Platform* is not exempt'
# No exemptions: units that used to be on the migration baseline fail too.
setup; printf 'unit DirReader;\n{$IFDEF DARWIN}\n{$ENDIF}\nend.\n' > "$T/src/units/DirReader.pas"; expect fail 'former baseline unit gets no exemption'
setup; printf 'program opendisk;\nuses\n  {$IFDEF UNIX}\n  cthreads, Unix,\n  {$ENDIF}\n  SysUtils;\nbegin\nend.\n' > "$T/src/opendisk.lpr"; expect fail 'cthreads guard that also pulls in another unit is not exempt'

exit $fail
