#!/usr/bin/env bash
# Regenerate website/public/og.png (1200x630) from scripts/og-card.html.
# Uses WeasyPrint (HTML -> PDF) + pdftoppm (PDF -> PNG) + sips (exact size).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
HTML="$DIR/og-card.html"
BUILD="$ROOT/.build"
OUT="$ROOT/public/og.png"

mkdir -p "$BUILD"
PDF="$BUILD/og-card.pdf"
RAW="$BUILD/og-raw"

weasyprint "$HTML" "$PDF"
pdftoppm -png -r 96 "$PDF" "$RAW"            # -> og-raw-1.png
sips -z 630 1200 "$RAW-1.png" --out "$OUT" >/dev/null  # force exact 1200x630

rm -f "$PDF" "$RAW"-*.png
echo "wrote $OUT"
sips -g pixelWidth -g pixelHeight "$OUT" | sed 's/^/  /'
