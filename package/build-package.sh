#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1786665600}
umask 022

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
OUT=${1:-"$ROOT/dist"}
ARCHIVE="$OUT/actionsquad.zip"
HASH_FILE="$ARCHIVE.sha256"

fail() {
  printf 'actionsquad package error: %s\n' "$*" >&2
  exit 1
}

[[ ! -e $ARCHIVE && ! -e $HASH_FILE ]] || fail "release output already exists: $OUT"
[[ -x $ROOT/build/actionsquad-nextos ]] || fail "build/actionsquad-nextos is missing"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/actionsquad-package.XXXXXX")
cleanup() {
  case $WORK in
    "${TMPDIR:-/tmp}"/actionsquad-package.*) rm -rf -- "$WORK" ;;
    *) printf 'refusing unsafe cleanup path: %s\n' "$WORK" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM
STAGE="$WORK/stage"
VERIFY="$WORK/verify"
mkdir -p -- "$STAGE" "$VERIFY" "$OUT"

put() {
  local mode=$1 source=$2 target=$3
  [[ -f $ROOT/$source && ! -L $ROOT/$source ]] || fail "unsafe or missing source: $source"
  install -D -m "$mode" -- "$ROOT/$source" "$STAGE/$target"
}

# Explicit allowlist: owner APK, native guest and extracted assets never enter.
put 0755 "Action Squad.sh" "Action Squad.sh"
put 0755 "build/actionsquad-nextos" "actionsquad/bin/aarch64/actionsquad-nextos"
put 0644 "actionsquad/nxport.json" "actionsquad/nxport.json"
put 0644 "actionsquad/nxproject.json" "actionsquad/nxproject.json"
put 0644 "actionsquad/port-env.sh" "actionsquad/port-env.sh"
put 0644 "actionsquad/extractor.json" "actionsquad/extractor.json"
put 0644 "actionsquad/nxextract/nxextract.py" "actionsquad/nxextract/nxextract.py"
put 0644 "actionsquad/nxextract/run-extractor.sh" "actionsquad/nxextract/run-extractor.sh"
put 0644 "actionsquad/nxextract/nxextract-runtime-env.sh" "actionsquad/nxextract/nxextract-runtime-env.sh"
put 0644 "actionsquad/port.json" "actionsquad/port.json"
put 0644 "actionsquad/alsoft.conf" "actionsquad/alsoft.conf"
put 0644 "actionsquad/README.md" "actionsquad/README.md"
put 0644 "actionsquad/INSTALLATION.md" "actionsquad/INSTALLATION.md"
put 0644 "actionsquad/LICENSE" "actionsquad/LICENSE"
put 0644 "actionsquad/NOTICE.md" "actionsquad/NOTICE.md"
put 0644 "actionsquad/version.txt" "actionsquad/version.txt"
put 0644 "actionsquad/FRAMEWORK-PIN.json" "actionsquad/FRAMEWORK-PIN.json"
put 0644 "actionsquad/adapter/adapter-contract.json" "actionsquad/adapter/adapter-contract.json"
put 0644 "actionsquad/gamedata/LEIA-ME.txt" "actionsquad/gamedata/LEIA-ME.txt"

[[ -f $STAGE/actionsquad/INSTALLATION.md ]] || fail "INSTALLATION.md path is wrong"
[[ $(sha256sum "$ROOT/actionsquad/INSTALLATION.md" | awk '{print $1}') == \
   $(sha256sum "$STAGE/actionsquad/INSTALLATION.md" | awk '{print $1}') ]] ||
  fail "INSTALLATION.md differs from the documented recipe"

if find "$STAGE" -type f \( -iname '*.apk' -o -iname '*.apkm' -o -iname '*.apks' \
  -o -iname '*.xapk' -o -iname '*.obb' -o -iname '*.dex' \
  -o -iname 'libAndroidEntryPoint.so' \) -print -quit | grep -q .; then
  fail "proprietary owner data leaked into release"
fi
[[ ! -e $STAGE/actionsquad/assets ]] || fail "proprietary assets leaked into release"

while IFS= read -r shell_path; do
  bash -n "$shell_path" || fail "shell syntax failed: $shell_path"
done < <(find "$STAGE" -type f -name '*.sh' -print | sort)

python3 - "$STAGE" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
external_stat = re.compile(r"(?<![A-Za-z0-9_./-])stat(?=\s|$)")
for path in root.rglob("*.sh"):
    for number, line in enumerate(path.read_text(errors="strict").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if external_stat.search(line):
            raise SystemExit(f"external stat command in {path.relative_to(root)}:{number}")
PY

python3 -B "$STAGE/actionsquad/nxextract/nxextract.py" recipe-check \
  --recipe "$STAGE/actionsquad/extractor.json" >/dev/null
[[ $(python3 -B "$STAGE/actionsquad/nxextract/nxextract.py" --version) == \
   'NXExtract 1.2.6' ]] || fail "NXExtract version drift"

ELF="$STAGE/actionsquad/bin/aarch64/actionsquad-nextos"
file "$ELF" | grep -q 'ARM aarch64' || fail "release executable is not AArch64"
[[ $(readelf -l "$ELF" | sed -n 's@.*Requesting program interpreter: \(.*\)]@\1@p') == \
   '/lib/ld-linux-aarch64.so.1' ]] || fail "unexpected ELF interpreter"
MAX_GLIBC=$(readelf --version-info "$ELF" |
  sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' | sort -Vu | tail -n 1)
[[ -n $MAX_GLIBC ]] || fail "cannot determine GLIBC requirement"
[[ $(printf '%s\n%s\n' 2.30 "$MAX_GLIBC" | sort -V | tail -n 1) == 2.30 ]] ||
  fail "ELF exceeds GLIBC_2.30: GLIBC_$MAX_GLIBC"
[[ $(find "$STAGE" -type f -exec file --brief {} \; | grep -c '^ELF ') == 1 ]] ||
  fail "unclassified or missing ELF in package"

(
  cd "$STAGE"
  find . -type f ! -path './actionsquad/RELEASE-MANIFEST.sha256' -print0 |
    sort -z | xargs -0 sha256sum > actionsquad/RELEASE-MANIFEST.sha256
)
find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

TMP_ARCHIVE="$WORK/actionsquad.zip"
(
  cd "$STAGE"
  find . -type f -printf '%P\n' | sort | zip -X -q -9 "$TMP_ARCHIVE" -@
)
unzip -q "$TMP_ARCHIVE" -d "$VERIFY"
[[ -f $VERIFY/actionsquad/INSTALLATION.md ]] || fail "final ZIP lost INSTALLATION.md"
[[ $(sha256sum "$VERIFY/actionsquad/INSTALLATION.md" | awk '{print $1}') == \
   $(sha256sum "$ROOT/actionsquad/INSTALLATION.md" | awk '{print $1}') ]] ||
  fail "final ZIP INSTALLATION.md hash mismatch"
(
  cd "$VERIFY"
  sha256sum -c actionsquad/RELEASE-MANIFEST.sha256 >/dev/null
)

install -m 0644 "$TMP_ARCHIVE" "$ARCHIVE"
(
  cd "$OUT"
  sha256sum actionsquad.zip > actionsquad.zip.sha256
)
printf 'release=%s\nmax_glibc=%s\n' "$ARCHIVE" "$MAX_GLIBC"
sha256sum "$ARCHIVE"
