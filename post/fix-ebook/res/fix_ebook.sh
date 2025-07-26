#!/usr/bin/env bash
set -Eeuo pipefail

# fix_epub.sh — normalize and validate EPUBs for Google Play Books ingestion.
# Usage:
#   fix_epub.sh [-r] [-v 2|3] [-k] INPUT.(epub|mobi|azw3)
# Options:
#   -r  Round-trip through MOBI before EPUB (can "regularize" stubborn files; slower; may lose some styling)
#   -v  Target EPUB version (2 or 3). Default: 3 with auto-fallback to 2 on validation failure
#   -k  Keep temp work dir (for debugging)
#
# Output: INPUT.fixed.epub (in same directory)

die() { echo "ERROR: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

require() {
  for c in "$@"; do have "$c" || die "Missing dependency: $c"; done
}

roundtrip=false
target_ver=3
keep_tmp=false

while getopts ":rv:k" opt; do
  case "$opt" in
    r) roundtrip=true ;;
    v) [[ "$OPTARG" =~ ^[23]$ ]] || die "-v must be 2 or 3"; target_ver="$OPTARG" ;;
    k) keep_tmp=true ;;
    \?) die "Unknown option: -$OPTARG" ;;
  esac
done
shift $((OPTIND-1))

[[ $# -eq 1 ]] || die "Provide exactly one input file. See --help in header."
inpath="$1"
[[ -f "$inpath" ]] || die "Input not found: $inpath"

inabs="$(readlink -f "$inpath" || realpath "$inpath")"
indir="$(dirname "$inabs")"
inbase="$(basename "$inabs")"
stem="${inbase%.*}"
outpath="${indir}/${stem}.fixed.epub"

require zip unzip mktemp
have ebook-convert || die "Calibre CLI 'ebook-convert' is required."
if ! have epubcheck; then
  echo "WARN: epubcheck not found; proceeding without validation." >&2
fi

tmp="$(mktemp -d -t fix_epub.XXXXXX)"
cleanup() { $keep_tmp || rm -rf "$tmp"; }
trap cleanup EXIT

log() { printf "[fix_epub] %s\n" "$*" >&2; }

# ---- helpers ----

# Build an EPUB zip with correct layout: 'mimetype' first and uncompressed.
# Args: SRC_EPUB -> DST_EPUB
repack_epub_proper() {
  local src="$1" dst="$2"
  local work="$tmp/repack"
  rm -rf "$work"; mkdir -p "$work"
  unzip -qq -o "$src" -d "$work"
  [[ -f "$work/mimetype" ]] || echo -n "application/epub+zip" > "$work/mimetype"

  ( cd "$work"
    # Start fresh
    rm -f "$dst"
    # 1) store mimetype uncompressed
    zip -X0 "$dst" mimetype >/dev/null
    # 2) add the rest, compressed, excluding mimetype
    zip -Xr9D "$dst" . -x mimetype >/dev/null
  )
}

# Try to polish with Calibre if available (optional).
polish_if_possible() {
  local src="$1" dst="$2"
  if have ebook-polish; then
    # Pretty-print, compress images, smarten punctuation.
    ebook-polish "$src" "$dst" --pretty-print --compress-images --smarten-punctuation >/dev/null 2>&1 || cp -f "$src" "$dst"
  else
    cp -f "$src" "$dst"
  fi
}

# Run epubcheck; return 0 if OK or epubcheck missing, nonzero if real errors.
validate_epub() {
  local file="$1"
  if have epubcheck; then
    # epubcheck exits nonzero on errors; warnings keep zero exit.
    epubcheck "$file" >/dev/null 2>&1
    return $?
  else
    return 0
  fi
}

# Convert with Calibre to EPUB with requested version and sane defaults
convert_to_epub() {
  local src="$1" dst="$2" ver="$3"
  # Safer across Calibre versions; all options are valid for EPUB output.
  ebook-convert "$src" "$dst" \
    --output-profile=default \
    --epub-version="$ver" \
    --embed-all-fonts \
    --subset-embedded-fonts \
    --epub-inline-toc \
    --pretty-print \
    --dont-split-on-page-breaks >/dev/null
}

# Optional MOBI round-trip using Calibre.
roundtrip_mobi_then_epub() {
  local src="$1" dst="$2" ver="$3"
  local m="$tmp/rt.mobi"
  ebook-convert "$src" "$m" --output-profile=kindle >/dev/null
  convert_to_epub "$m" "$dst" "$ver"
}

# ---- pipeline ----

log "Input : $inabs"
log "Output: $outpath"

work_epub="$tmp/work.epub"

if $roundtrip; then
  log "Round-tripping through MOBI..."
  roundtrip_mobi_then_epub "$inabs" "$work_epub" "$target_ver"
else
  convert_to_epub "$inabs" "$work_epub" "$target_ver"
fi

polished="$tmp/polished.epub"
polish_if_possible "$work_epub" "$polished"

# Ensure proper zip/mimetype layout
repacked="$tmp/repacked.epub"
repack_epub_proper "$polished" "$repacked"

# Validate; auto-fallback from 3 -> 2 if needed
attempts=1
ver_used="$target_ver"

if ! validate_epub "$repacked"; then
  if [[ "$target_ver" -eq 3 ]]; then
    log "Validation failed on EPUB3; retrying as EPUB2…"
    ver_used=2
    if $roundtrip; then
      roundtrip_mobi_then_epub "$inabs" "$work_epub" "2"
    else
      convert_to_epub "$inabs" "$work_epub" "2"
    fi
    polish_if_possible "$work_epub" "$polished"
    repack_epub_proper "$polished" "$repacked"
    attempts=2
    if ! validate_epub "$repacked"; then
      log "WARN: Validation still failing on EPUB2; outputting anyway."
    else
      log "Validated OK as EPUB2."
    fi
  else
    log "WARN: Validation failed on EPUB${target_ver}; outputting anyway."
  fi
else
  log "Validated OK as EPUB${ver_used}."
fi

# Finalize
mv -f "$repacked" "$outpath"
log "Done. Wrote: $outpath"
if [[ $attempts -eq 2 ]]; then
  log "Note: Auto-fallback used (3→2)."
fi

# Optionally keep temp dir for debugging.
if $keep_tmp; then
  echo "[fix_epub] Temp dir kept at: $tmp" >&2
else
  rm -rf "$tmp"
fi
