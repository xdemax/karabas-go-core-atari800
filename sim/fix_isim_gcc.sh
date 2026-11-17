#!/bin/bash
# Prepare a copy of the ISE 14.7 ISim "fuse" that works with GCC 14+.
#
# ISim generates C files without prototypes; GCC 14 makes implicit function
# declarations an error.  We replace the compiler path inside a *copy* of fuse
# with a wrapper that downgrades it to a warning.
#
# The replacement must be exactly 12 characters long (as "/usr/bin/gcc"):
# /tmp/xxx/gcc.
set -euo pipefail

WRAP_DIR=/tmp/xxx
WRAP=$WRAP_DIR/gcc
PATCHED=/tmp/opencode/fuse_patched
SRC=/opt/Xilinx/14.7/ISE_DS/ISE/bin/lin64/unwrapped/fuse

[ -x "$SRC" ] || { echo "ISE fuse not found: $SRC" >&2; exit 1; }

mkdir -p "$WRAP_DIR"
cat > "$WRAP" <<'EOF'
#!/bin/sh
exec /usr/bin/gcc -Wno-implicit-function-declaration "$@"
EOF
chmod +x "$WRAP"

mkdir -p "$(dirname "$PATCHED")"
if [ ! -x "$PATCHED" ] || ! python3 - "$PATCHED" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if b'/tmp/xxx/gcc' in d else 1)
PY
then
	cp -f "$SRC" "$PATCHED"
	python3 - "$PATCHED" <<'PY'
import sys
p = sys.argv[1]
d = open(p, 'rb').read()
n = d.count(b'/usr/bin/gcc')
if n == 0:
    sys.exit('no /usr/bin/gcc string in fuse')
d = d.replace(b'/usr/bin/gcc', b'/tmp/xxx/gcc')
open(p, 'wb').write(d)
print('patched %d compiler path(s) in %s' % (n, p))
PY
	chmod +x "$PATCHED"
fi

echo "$PATCHED"
