#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:---source-only}"

echo "==> [Audit 1/3] Scanning Swift/ObjC/C sources for network frameworks or socket calls..."
NETWORK_CALLS='socket|socketpair|connect|connectx|bind|listen|accept|accept4|send|sendto|sendmsg|recv|recvfrom|recvmsg|getaddrinfo|gethostbyname|gethostbyname2|res_query|res_9_query'
NETWORK_APIS='URLSession|NSURLConnection|NWConnection|NWListener|NWPathMonitor|CFSocket|CFHost|CFStreamCreatePairWithSocket|SCNetworkReachability|WKWebView|SFSafariViewController|DNSService(Browse|Resolve|Register)|NetServiceBrowser'
FORBIDDEN_SOURCE_REGEX="(import[[:space:]]+(Network|CFNetwork|WebKit|SafariServices|AdSupport|AppTrackingTransparency)|${NETWORK_APIS}|(^|[^[:alnum:]_])(${NETWORK_CALLS})[[:space:]]*\()"

if /usr/bin/grep -R -n -E --include='*.swift' --include='*.m' --include='*.mm' --include='*.c' --include='*.h' "$FORBIDDEN_SOURCE_REGEX" \
  "$PROJECT_DIR/AuditDemoApp" "$PROJECT_DIR/KeyboardExtension" "$PROJECT_DIR/Shared/Engine"; then
  echo "❌ Audit failed: forbidden network API reference detected in source!" >&2
  exit 1
else
  [[ $? == 1 ]] || exit 1
fi
echo "    ✓ Source scan passed (0 network frameworks / 0 socket calls)."

echo "==> [Audit 2/3] Validating Info.plist & App Group entitlements sandbox isolation..."
audit_plists() {
  python3 - "$1" "$2" <<'PLIST'
import plistlib
import sys

with open(sys.argv[1], 'rb') as src:
    info = plistlib.load(src)
with open(sys.argv[2], 'rb') as src:
    entitlements = plistlib.load(src)

for key in ('NSAppTransportSecurity', 'UIBackgroundModes', 'NSLocalNetworkUsageDescription', 'NSBonjourServices'):
    if key in info:
        sys.exit(f"❌ {sys.argv[1]} contains forbidden key {key}")
for key in ('UIFileSharingEnabled', 'LSSupportsOpeningDocumentsInPlace'):
    if info.get(key, False) is not False:
        sys.exit(f"❌ {sys.argv[1]} enables {key}")
if 'group.com.kianuni.lokey' not in entitlements.get('com.apple.security.application-groups', []):
    sys.exit(f"❌ {sys.argv[2]} is missing required App Group group.com.kianuni.lokey")
for key in entitlements:
    if any(marker in key.lower() for marker in ('aps-environment', 'icloud', 'ubiquity', 'networking', 'multipath')):
        sys.exit(f"❌ {sys.argv[2]} contains forbidden entitlement {key}")
PLIST
}

audit_info_only() {
  python3 - "$1" <<'INFOONLY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as src:
    info = plistlib.load(src)

for key in ('NSAppTransportSecurity', 'UIBackgroundModes', 'NSLocalNetworkUsageDescription', 'NSBonjourServices'):
    if key in info:
        sys.exit(f"❌ {sys.argv[1]} contains forbidden key {key}")
for key in ('UIFileSharingEnabled', 'LSSupportsOpeningDocumentsInPlace'):
    if info.get(key, False) is not False:
        sys.exit(f"❌ {sys.argv[1]} enables {key}")
INFOONLY
}

audit_plists "$PROJECT_DIR/AuditDemoApp/Info.plist" "$PROJECT_DIR/AuditDemoApp/AuditDemoApp.entitlements"
audit_plists "$PROJECT_DIR/KeyboardExtension/Info.plist" "$PROJECT_DIR/KeyboardExtension/LokeyKeyboard.entitlements"
echo "    ✓ Info.plist and App Group entitlements audit passed."

if [[ "$TARGET" == "--source-only" ]]; then
  echo "==> Source-only zero-network audit completed."
  exit 0
fi

if [[ ! -e "$TARGET" ]]; then
  echo "❌ Target path does not exist: $TARGET" >&2
  exit 1
fi

TMP_AUDIT_DIR="$(/usr/bin/mktemp -d)"
trap 'rm -rf "$TMP_AUDIT_DIR"' EXIT

typeset -a BUNDLES
BUNDLES=()

if [[ -f "$TARGET" && "$TARGET" == *.ipa ]]; then
  /usr/bin/unzip -q "$TARGET" -d "$TMP_AUDIT_DIR"
  while IFS= read -r b; do
    BUNDLES+=("$b")
  done < <(/usr/bin/find "$TMP_AUDIT_DIR/Payload" -maxdepth 4 \( -name "*.app" -o -name "*.appex" \) | /usr/bin/sort)
elif [[ -d "$TARGET" && "$TARGET" == *.app ]]; then
  BUNDLES+=("$TARGET")
  if [[ -d "$TARGET/PlugIns" ]]; then
    while IFS= read -r b; do
      BUNDLES+=("$b")
    done < <(/usr/bin/find "$TARGET/PlugIns" -maxdepth 2 -name "*.appex" | /usr/bin/sort)
  fi
elif [[ -d "$TARGET" && "$TARGET" == *.appex ]]; then
  BUNDLES+=("$TARGET")
elif [[ -d "$TARGET" ]]; then
  while IFS= read -r b; do
    BUNDLES+=("$b")
  done < <(/usr/bin/find "$TARGET" -maxdepth 6 -not -path "*/Index.noindex/*" \( -name "*.app" -o -name "*.appex" \) | /usr/bin/sort)
else
  echo "❌ Unsupported audit target (expected --source-only, .app, .appex, build dir, or .ipa): $TARGET" >&2
  exit 1
fi

if (( ${#BUNDLES[@]} == 0 )); then
  echo "❌ Audit failed: no .app or .appex bundles found under $TARGET" >&2
  exit 1
fi

for BUNDLE in "${BUNDLES[@]}"; do
  BUNDLE_NAME="$(basename "$BUNDLE")"
  INFO_PLIST="$BUNDLE/Info.plist"
  if [[ ! -f "$INFO_PLIST" ]]; then
    echo "❌ Audit failed: missing Info.plist in $BUNDLE" >&2
    exit 1
  fi

  EXEC_NAME="$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleExecutable"])' "$INFO_PLIST")"
  MAIN_BIN="$BUNDLE/$EXEC_NAME"
  if [[ ! -f "$MAIN_BIN" ]]; then
    echo "❌ Audit failed: missing Mach-O executable $MAIN_BIN" >&2
    exit 1
  fi

  ENT_VALIDATED=0
  if /usr/bin/codesign -d --entitlements - --xml "$BUNDLE" > "$TMP_AUDIT_DIR/entitlements.plist" 2>/dev/null && [[ -s "$TMP_AUDIT_DIR/entitlements.plist" ]]; then
    if python3 -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); sys.exit(0 if d else 1)' "$TMP_AUDIT_DIR/entitlements.plist" 2>/dev/null; then
      audit_plists "$INFO_PLIST" "$TMP_AUDIT_DIR/entitlements.plist"
      ENT_VALIDATED=1
    fi
  fi

  if [[ "$ENT_VALIDATED" == "0" ]]; then
    # iOS Simulator builds embed entitlements inside Mach-O (__TEXT,__entitlements) rather than LC_CODE_SIGNATURE.
    if python3 - "$MAIN_BIN" "$TMP_AUDIT_DIR/macho_entitlements.plist" <<'MACHO_ENT'
import plistlib
import struct
import sys

data = open(sys.argv[1], "rb").read()
if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
    sys.exit(1)
ncmds = struct.unpack_from("<I", data, 16)[0]
off = 32
for _ in range(ncmds):
    if off + 8 > len(data):
        break
    cmd, cmdsize = struct.unpack_from("<II", data, off)
    if cmdsize < 8 or off + cmdsize > len(data):
        break
    if cmd == 0x19:  # LC_SEGMENT_64
        segname = data[off + 8 : off + 24].split(b"\x00", 1)[0]
        if segname == b"__TEXT":
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            sec_off = off + 72
            for _ in range(nsects):
                if sec_off + 80 > off + cmdsize:
                    break
                sectname = data[sec_off : sec_off + 16].split(b"\x00", 1)[0]
                if sectname == b"__entitlements":
                    size = struct.unpack_from("<Q", data, sec_off + 40)[0]
                    foff = struct.unpack_from("<I", data, sec_off + 48)[0]
                    raw_ent = data[foff : foff + size]
                    plistlib.loads(raw_ent)
                    open(sys.argv[2], "wb").write(raw_ent)
                    sys.exit(0)
                sec_off += 80
    off += cmdsize
sys.exit(1)
MACHO_ENT
    then
      audit_plists "$INFO_PLIST" "$TMP_AUDIT_DIR/macho_entitlements.plist"
    elif /usr/bin/codesign -v "$BUNDLE" >/dev/null 2>&1; then
      echo "❌ Audit failed: signed bundle $BUNDLE_NAME is missing entitlements!" >&2
      exit 1
    else
      audit_info_only "$INFO_PLIST"
    fi
  fi

  typeset -a MACH_O_BINS
  MACH_O_BINS=("$MAIN_BIN")
  if [[ -f "${MAIN_BIN}.debug.dylib" ]]; then
    MACH_O_BINS+=("${MAIN_BIN}.debug.dylib")
  fi

  for BIN in "${MACH_O_BINS[@]}"; do
    BIN_LABEL="$(basename "$BIN")"
    echo "==> [Audit 3/3] Auditing Mach-O dylibs & undefined symbols: $BUNDLE_NAME/$BIN_LABEL"

    /usr/bin/otool -L "$BIN" > "$TMP_AUDIT_DIR/libraries"
    /usr/bin/nm -u "$BIN" > "$TMP_AUDIT_DIR/imports"

    if /usr/bin/grep -E '((Network|CFNetwork|WebKit|SafariServices|NetworkExtension|SystemConfiguration|AdSupport|AppTrackingTransparency|MultipeerConnectivity|LinkPresentation)\.framework|lib(network|resolv|dns_sd)[.])' "$TMP_AUDIT_DIR/libraries"; then
      echo "❌ Audit failed: $BIN_LABEL links a forbidden network framework!" >&2
      exit 1
    else
      [[ $? == 1 ]] || exit 1
    fi

    if /usr/bin/grep -E "(^|[[:space:]])_(${NETWORK_CALLS})([\$].*)?$|[[:space:]]_(nw_|DNSService)|${NETWORK_APIS}" "$TMP_AUDIT_DIR/imports"; then
      echo "❌ Audit failed: $BIN_LABEL imports a forbidden network/socket symbol!" >&2
      exit 1
    else
      [[ $? == 1 ]] || exit 1
    fi

    echo "    ✓ $BUNDLE_NAME/$BIN_LABEL passed (0 network frameworks / 0 socket symbols)."
  done
done

echo "✅ Zero-network Mach-O and sandbox isolation audit passed for: $TARGET"
