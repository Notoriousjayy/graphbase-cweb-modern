#!/usr/bin/env bash
set -Eeuo pipefail

# Recursively build every .tex, .plaintex, and .w (CWEB) file under a
# repository into a PDF.
#
# - Detects plain TeX vs LaTeX automatically and selects the right engine.
# - Weaves .w files with cweave before compiling.
# - Skips macro/include files that are not standalone documents.
# - Uses latexmk for LaTeX documents when available; calls pdftex/pdflatex
#   directly for plain TeX documents (latexmk is not reliable for plain TeX).
# - Places output in a sibling build directory named by $OUTDIR_NAME.
#
# Usage:
#   ./build-all-tex-to-pdfs.sh [root]
#
# Examples:
#   ./build-all-tex-to-pdfs.sh
#   ./build-all-tex-to-pdfs.sh ./notoriousjayy-graphbase-cweb-modern
#
# Optional environment variables:
#   OUTDIR_NAME=build-pdf
#   LATEXMK=latexmk
#   PDFLATEX=pdflatex
#   PDFTEX=pdftex
#   CWEAVE=cweave
#   STRICT=1        # exit non-zero if any file fails
#   VERBOSE=1       # stream compiler output to terminal

ROOT="${1:-.}"
OUTDIR_NAME="${OUTDIR_NAME:-build-pdf}"
LATEXMK="${LATEXMK:-latexmk}"
PDFLATEX="${PDFLATEX:-pdflatex}"
PDFTEX="${PDFTEX:-pdftex}"
CWEAVE="${CWEAVE:-cweave}"
STRICT="${STRICT:-0}"
VERBOSE="${VERBOSE:-0}"

if [[ ! -d "$ROOT" ]]; then
  echo "error: root directory does not exist: $ROOT" >&2
  exit 2
fi

have_latexmk=0
have_pdflatex=0
have_pdftex=0
have_cweave=0

if command -v "$LATEXMK" >/dev/null 2>&1; then
  have_latexmk=1
fi

if command -v "$PDFLATEX" >/dev/null 2>&1; then
  have_pdflatex=1
fi

if command -v "$PDFTEX" >/dev/null 2>&1; then
  have_pdftex=1
fi

if command -v "$CWEAVE" >/dev/null 2>&1; then
  have_cweave=1
fi

if [[ "$have_latexmk" -eq 0 && "$have_pdflatex" -eq 0 && "$have_pdftex" -eq 0 ]]; then
  cat >&2 <<'EOF'
error: no TeX builder found.
Install one of:
  - latexmk
  - pdflatex
  - pdftex
On Debian/Ubuntu, for example:
  sudo apt update
  sudo apt install -y latexmk texlive-latex-base texlive-latex-recommended texlive-fonts-recommended
EOF
  exit 3
fi

# Collect all buildable source files: .tex, .plaintex, .w
mapfile -d '' SRC_FILES < <(
  find "$ROOT" -type f \( -name '*.tex' -o -name '*.plaintex' -o -name '*.w' \) -print0 | sort -z
)

if [[ "${#SRC_FILES[@]}" -eq 0 ]]; then
  echo "No .tex, .plaintex, or .w files found under: $ROOT"
  exit 0
fi

successes=()
failures=()
skipped=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Determine whether a .tex file is a LaTeX document (contains \documentclass
# or \begin{document}).  Returns 0 for LaTeX, 1 for plain TeX.
is_latex() {
  local file="$1"
  grep -qE '\\documentclass|\\begin\{document\}' "$file" 2>/dev/null
}

# Determine whether a .tex file is a standalone document (as opposed to a
# macro/include file).  A standalone document contains either:
#   - \bye              (plain TeX terminator)
#   - \end{document}    (LaTeX terminator)
#   - \input cwebmac    (CWEB document — these end with \inx, \fin, \con, etc.)
# Macro packages that lack all of the above are skipped.
is_standalone_tex() {
  local file="$1"
  grep -qE '\\bye(\s|$|%)|\\end\{document\}|\\input cwebmac' "$file" 2>/dev/null
}

# Determine whether a .w file is a standalone CWEB document (as opposed to
# an include file like boilerplate.w, gb_types.w, xlib_types.w).
# Standalone CWEB documents contain @* (named section start); include-only
# files contain only @s, @q, @i, or TeX macro definitions.
is_standalone_w() {
  local file="$1"
  grep -qE '^@\*' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Build functions
# ---------------------------------------------------------------------------

# Build a plain TeX file (.tex or .plaintex) directly with pdftex.
# Latexmk is intentionally bypassed — its dependency tracking is designed
# for LaTeX and does not work reliably with plain TeX / CWEB documents.
build_plaintex() {
  local src="$1" dir base stem outdir logfile pdfpath rc

  dir="$(dirname "$src")"
  base="$(basename "$src")"
  stem="${base%.*}"
  outdir="$dir/$OUTDIR_NAME"
  logfile="$outdir/${stem}.build.log"
  pdfpath="$outdir/${stem}.pdf"

  mkdir -p "$outdir"

  echo "==> Building $src  [plain TeX → pdftex]"

  if [[ "$have_pdftex" -eq 0 ]]; then
    echo "    SKIP: pdftex not found (needed for plain TeX file)" >&2
    skipped+=("$src (pdftex not installed)")
    return 1
  fi

  # Two passes handle cross-references (TOC, index, section numbers).
  if [[ "$VERBOSE" -eq 1 ]]; then
    (
      cd "$dir"
      "$PDFTEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "$base" &&
      "$PDFTEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "$base"
    ) 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
  else
    (
      cd "$dir"
      "$PDFTEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "$base" &&
      "$PDFTEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "$base"
    ) >"$logfile" 2>&1
    rc=$?
  fi

  if [[ "$rc" -eq 0 && -f "$pdfpath" ]]; then
    successes+=("$src -> $pdfpath")
    echo "    OK: $pdfpath"
    return 0
  fi

  failures+=("$src (see $logfile)")
  echo "    FAIL: $src"
  echo "          log: $logfile"
  return 1
}

# Build a LaTeX document with latexmk (preferred) or pdflatex fallback.
build_latex() {
  local tex="$1" dir base stem outdir logfile pdfpath rc

  dir="$(dirname "$tex")"
  base="$(basename "$tex")"
  stem="${base%.tex}"
  outdir="$dir/$OUTDIR_NAME"
  logfile="$outdir/${stem}.build.log"
  pdfpath="$outdir/${stem}.pdf"

  mkdir -p "$outdir"

  echo "==> Building $tex  [LaTeX → pdflatex]"

  if [[ "$have_latexmk" -eq 1 ]]; then
    if [[ "$VERBOSE" -eq 1 ]]; then
      (
        cd "$dir"
        "$LATEXMK" \
          -pdf \
          -interaction=nonstopmode \
          -halt-on-error \
          -file-line-error \
          -outdir="$OUTDIR_NAME" \
          "$base"
      ) 2>&1 | tee "$logfile"
      rc=${PIPESTATUS[0]}
    else
      (
        cd "$dir"
        "$LATEXMK" \
          -pdf \
          -interaction=nonstopmode \
          -halt-on-error \
          -file-line-error \
          -outdir="$OUTDIR_NAME" \
          "$base"
      ) >"$logfile" 2>&1
      rc=$?
    fi
  elif [[ "$have_pdflatex" -eq 1 ]]; then
    if [[ "$VERBOSE" -eq 1 ]]; then
      (
        cd "$dir"
        "$PDFLATEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "$base" &&
        "$PDFLATEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "$base"
      ) 2>&1 | tee "$logfile"
      rc=${PIPESTATUS[0]}
    else
      (
        cd "$dir"
        "$PDFLATEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "$base" &&
        "$PDFLATEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "$base"
      ) >"$logfile" 2>&1
      rc=$?
    fi
  else
    echo "    SKIP: pdflatex not found (needed for LaTeX file)" >&2
    skipped+=("$tex (pdflatex not installed)")
    return 1
  fi

  if [[ "$rc" -eq 0 && -f "$pdfpath" ]]; then
    successes+=("$tex -> $pdfpath")
    echo "    OK: $pdfpath"
    return 0
  fi

  failures+=("$tex (see $logfile)")
  echo "    FAIL: $tex"
  echo "          log: $logfile"
  return 1
}

# Build a CWEB .w file: cweave → .tex → pdftex.
# If a matching .ch (change file) exists alongside the .w, it is passed
# to cweave automatically (following the Stanford GraphBase convention).
build_cweb() {
  local wfile="$1" dir base stem outdir logfile texfile pdfpath rc

  dir="$(dirname "$wfile")"
  base="$(basename "$wfile")"
  stem="${base%.w}"
  outdir="$dir/$OUTDIR_NAME"
  logfile="$outdir/${stem}.build.log"
  texfile="$dir/${stem}.tex"
  pdfpath="$outdir/${stem}.pdf"

  mkdir -p "$outdir"

  echo "==> Building $wfile  [CWEB → cweave → pdftex]"

  if [[ "$have_cweave" -eq 0 ]]; then
    echo "    SKIP: cweave not found (needed for .w files)" >&2
    skipped+=("$wfile (cweave not installed)")
    return 1
  fi

  if [[ "$have_pdftex" -eq 0 ]]; then
    echo "    SKIP: pdftex not found (needed for plain TeX output)" >&2
    skipped+=("$wfile (pdftex not installed)")
    return 1
  fi

  # --- Step 1: Weave .w → .tex -------------------------------------------
  if [[ "$VERBOSE" -eq 1 ]]; then
    (
      cd "$dir"
      if [[ -r "${stem}.ch" ]]; then
        "$CWEAVE" "$base" "${stem}.ch"
      else
        "$CWEAVE" "$base"
      fi
    ) 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
  else
    (
      cd "$dir"
      if [[ -r "${stem}.ch" ]]; then
        "$CWEAVE" "$base" "${stem}.ch"
      else
        "$CWEAVE" "$base"
      fi
    ) >"$logfile" 2>&1
    rc=$?
  fi

  if [[ ! -f "$texfile" ]]; then
    failures+=("$wfile (cweave failed — see $logfile)")
    echo "    FAIL: $wfile  [cweave step — no .tex produced]"
    echo "          log: $logfile"
    return 1
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo "    WARN: cweave exited with code $rc but produced ${stem}.tex — continuing"
  fi

  # --- Step 2: Compile .tex → .pdf with pdftex ---------------------------
  # Two passes for cross-references.
  if [[ "$VERBOSE" -eq 1 ]]; then
    (
      cd "$dir"
      "$PDFTEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "${stem}.tex" &&
      "$PDFTEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "${stem}.tex"
    ) 2>&1 | tee -a "$logfile"
    rc=${PIPESTATUS[0]}
  else
    (
      cd "$dir"
      "$PDFTEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "${stem}.tex" &&
      "$PDFTEX" -interaction=nonstopmode -halt-on-error -file-line-error -output-directory="$OUTDIR_NAME" "${stem}.tex"
    ) >>"$logfile" 2>&1
    rc=$?
  fi

  if [[ "$rc" -eq 0 && -f "$pdfpath" ]]; then
    successes+=("$wfile -> $pdfpath")
    echo "    OK: $pdfpath"
    return 0
  fi

  failures+=("$wfile (see $logfile)")
  echo "    FAIL: $wfile  [pdftex step]"
  echo "          log: $logfile"
  return 1
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

for src in "${SRC_FILES[@]}"; do
  ext="${src##*.}"

  case "$ext" in

    # --- .w (CWEB web) files ----------------------------------------------
    w)
      if ! is_standalone_w "$src"; then
        echo "==> Skipping $src  [CWEB include file — not a standalone document]"
        skipped+=("$src (CWEB include file)")
        continue
      fi

      # If a pre-existing .tex already exists for this .w file (e.g. the
      # cweb/ distribution ships pre-woven .tex), skip the .w to avoid
      # building the same document twice.
      stem="$(basename "$src" .w)"
      dir="$(dirname "$src")"
      if [[ -f "$dir/${stem}.tex" ]]; then
        echo "==> Skipping $src  [pre-existing .tex found — will build that instead]"
        skipped+=("$src (pre-existing .tex)")
        continue
      fi

      build_cweb "$src" || {
        if [[ "$STRICT" -eq 1 ]]; then
          echo
          echo "Stopping because STRICT=1"
          break
        fi
      }
      ;;

    # --- .plaintex files --------------------------------------------------
    plaintex)
      build_plaintex "$src" || {
        if [[ "$STRICT" -eq 1 ]]; then
          echo
          echo "Stopping because STRICT=1"
          break
        fi
      }
      ;;

    # --- .tex files -------------------------------------------------------
    tex)
      # Skip non-standalone files (macro packages, include files)
      if ! is_standalone_tex "$src"; then
        echo "==> Skipping $src  [macro/include file — not a standalone document]"
        skipped+=("$src (macro/include file)")
        continue
      fi

      # Route to the correct engine
      if is_latex "$src"; then
        build_latex "$src" || {
          if [[ "$STRICT" -eq 1 ]]; then
            echo
            echo "Stopping because STRICT=1"
            break
          fi
        }
      else
        build_plaintex "$src" || {
          if [[ "$STRICT" -eq 1 ]]; then
            echo
            echo "Stopping because STRICT=1"
            break
          fi
        }
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "Build summary"
echo "-------------"
echo "Succeeded: ${#successes[@]}"
for item in "${successes[@]}"; do
  echo "  - $item"
done

echo "Skipped: ${#skipped[@]}"
for item in "${skipped[@]}"; do
  echo "  - $item"
done

echo "Failed: ${#failures[@]}"
for item in "${failures[@]}"; do
  echo "  - $item"
done

if [[ "${#failures[@]}" -gt 0 ]]; then
  cat <<'EOF'

Notes:
- Re-run with VERBOSE=1 to see compiler output live.
EOF
fi

if [[ "$STRICT" -eq 1 && "${#failures[@]}" -gt 0 ]]; then
  exit 1
fi