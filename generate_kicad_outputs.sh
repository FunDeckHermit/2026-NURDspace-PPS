#!/usr/bin/env bash
set -euo pipefail

START_TIME=$(date +%s)
RUN_DATETIME="$(date +"%Y-%m-%d %H:%M:%S")"

OUTPUT_DIR="${1:-kicad-artifacts}"

echo "Output directory: ${OUTPUT_DIR}"

###############################################################################
# Check dependencies upfront
###############################################################################

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command '$1' not found. Install with:"
        
        # Detect package manager
        if command -v dnf >/dev/null 2>&1; then
            case "$1" in
                zip) echo "  sudo dnf install zip" ;;
                gawk) echo "  sudo dnf install gawk" ;;
                sed) echo "  sudo dnf install sed" ;;
                find) echo "  sudo dnf install findutils" ;;
                *) echo "  sudo dnf install $1" ;;
            esac
        elif command -v pacman >/dev/null 2>&1; then
            case "$1" in
                zip) echo "  sudo pacman -S zip" ;;
                gawk) echo "  sudo pacman -S gawk" ;;
                sed) echo "  sudo pacman -S sed" ;;
                find) echo "  sudo pacman -S findutils" ;;
                *) echo "  sudo pacman -S $1" ;;
            esac
        elif command -v apt-get >/dev/null 2>&1; then
            case "$1" in
                zip) echo "  sudo apt-get install zip" ;;
                gawk) echo "  sudo apt-get install gawk" ;;
                sed) echo "  sudo apt-get install sed" ;;
                find) echo "  sudo apt-get install findutils" ;;
                *) echo "  sudo apt-get install $1" ;;
            esac
        else
            echo "  Please install $1 using your package manager"
        fi
        exit 1
    fi
}

echo "Checking dependencies…"
check_command "zip"
check_command "gawk"
check_command "sed"
check_command "find"

###############################################################################
# Setup error trap for cleanup on failure
###############################################################################

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: Script failed with exit code $exit_code"
        echo "Cleaning up incomplete output directory: $OUTPUT_DIR"
        rm -rf "$OUTPUT_DIR"
    fi
    exit $exit_code
}

trap cleanup_on_error EXIT

###############################################################################
# Clean output directory if it already exists
###############################################################################

if [[ -d "$OUTPUT_DIR" ]]; then
    echo "Cleaning existing output directory: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
fi

mkdir -p "$OUTPUT_DIR"

###############################################################################
# Detect KiCad CLI (native first, then Flatpak)
###############################################################################

KICAD_CLI=""
USE_FLATPAK=false

if command -v kicad-cli >/dev/null 2>&1; then
    echo "Found native KiCad installation."
    KICAD_CLI="kicad-cli"
fi

if [[ -z "$KICAD_CLI" ]] && command -v flatpak >/dev/null 2>&1; then
    if flatpak info org.kicad.KiCad >/dev/null 2>&1; then
        echo "Found KiCad via Flatpak (org.kicad.KiCad)"
        KICAD_CLI="flatpak run --command=kicad-cli org.kicad.KiCad"
        USE_FLATPAK=true
    elif flatpak info org.kicad_pcb.KiCad >/dev/null 2>&1; then
        echo "Found KiCad via Flatpak (org.kicad_pcb.KiCad)"
        KICAD_CLI="flatpak run --command=kicad-cli org.kicad_pcb.KiCad"
        USE_FLATPAK=true
    fi
fi

if [[ -z "$KICAD_CLI" ]]; then
    echo "ERROR: KiCad not found (native or Flatpak)."
    exit 1
fi

echo "Using KiCad CLI: $KICAD_CLI"

###############################################################################
# Locate project files
###############################################################################

PROJ_FILE=$(find . -maxdepth 1 -type f -name "*.kicad_pro" | head -n 1 || true)
if [[ -z "$PROJ_FILE" ]]; then
    echo "ERROR: No *.kicad_pro file found!"
    exit 1
fi

BASE="${PROJ_FILE%.kicad_pro}"
SCHEMATIC="${BASE}.kicad_sch"
PCB="${BASE}.kicad_pcb"

PROJECT_NAME=$(basename "$BASE")

[[ -f "$SCHEMATIC" ]] || { echo "ERROR: Missing: $SCHEMATIC"; exit 1; }
[[ -f "$PCB" ]]       || { echo "ERROR: Missing: $PCB"; exit 1; }

echo "Project name: $PROJECT_NAME"
echo "Schematic:    $SCHEMATIC"
echo "PCB:          $PCB"

###############################################################################
# Prepare folders
###############################################################################

mkdir -p "$OUTPUT_DIR/drill"
mkdir -p "$OUTPUT_DIR/gerbers"
MP_DIR="$OUTPUT_DIR/pcb-multipage"
mkdir -p "$MP_DIR"

REPORT_FILE="$OUTPUT_DIR/report.txt"
LOG_FILE="$OUTPUT_DIR/build.log"

# Start logging
exec > >(tee -a "$LOG_FILE")
exec 2>&1

###############################################################################
# Detect PCB layers from KiCad PCB file
###############################################################################

detect_layers() {
    # Extract layer information from PCB file
    # Look for common layer definitions and build the layer string
    local layers="F.Cu,B.Cu,F.Mask,B.Mask,F.Paste,B.Paste,F.SilkS,B.SilkS,Edge.Cuts"
    
    # Try to detect inner layers
    if grep -q "In1.Cu" "$PCB"; then
        layers="F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.Paste,B.Paste,F.SilkS,B.SilkS,Edge.Cuts"
    fi
    
    if grep -q "In3.Cu" "$PCB"; then
        layers="F.Cu,In1.Cu,In2.Cu,In3.Cu,B.Cu,F.Mask,B.Mask,F.Paste,B.Paste,F.SilkS,B.SilkS,Edge.Cuts"
    fi
    
    echo "$layers"
}

GERBER_LAYERS=$(detect_layers)
echo "Detected gerber layers: $GERBER_LAYERS"

###############################################################################
# Helper function to run KiCad commands with error checking
###############################################################################

run_kicad_cmd() {
    local description="$1"
    shift
    
    echo "→ $description"
    if ! "$@"; then
        echo "ERROR: $description failed!"
        return 1
    fi
}

###############################################################################
# Schematic PDF
###############################################################################

run_kicad_cmd "Exporting schematic PDF" \
    $KICAD_CLI sch export pdf "$SCHEMATIC" \
    --output "$OUTPUT_DIR/${PROJECT_NAME}_schematic.pdf"

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_schematic.pdf" ]] || {
    echo "ERROR: Schematic PDF was not created!"
    exit 1
}

###############################################################################
# PCB PDF (multipage workaround)
###############################################################################

run_kicad_cmd "Exporting PCB PDF" \
    $KICAD_CLI pcb export pdf "$PCB" \
    --layers F.Cu,In1.Cu,In2.Cu,B.Cu \
    --mode-multipage \
    --output "$MP_DIR"

INNER_PDF=$(find "$MP_DIR" -maxdepth 1 -type f -name '*.pdf' | head -n 1 || true)
if [[ -z "$INNER_PDF" ]]; then
    echo "ERROR: PCB PDF not generated!"
    exit 1
fi

mv "$INNER_PDF" "$OUTPUT_DIR/${PROJECT_NAME}_pcb.pdf"
rm -rf "$MP_DIR"

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_pcb.pdf" ]] || {
    echo "ERROR: PCB PDF move failed!"
    exit 1
}

###############################################################################
# High-quality renders
###############################################################################

RENDER_WIDTH=1400
RENDER_HEIGHT=1400
RENDER_QUALITY="high"

run_kicad_cmd "Exporting top render" \
    $KICAD_CLI pcb render "$PCB" \
    --side top \
    --quality "$RENDER_QUALITY" \
    --width "$RENDER_WIDTH" \
    --height "$RENDER_HEIGHT" \
    --output "$OUTPUT_DIR/${PROJECT_NAME}_render-top.png"

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_render-top.png" ]] || {
    echo "ERROR: Top render was not created!"
    exit 1
}

run_kicad_cmd "Exporting bottom render" \
    $KICAD_CLI pcb render "$PCB" \
    --side bottom \
    --quality "$RENDER_QUALITY" \
    --width "$RENDER_WIDTH" \
    --height "$RENDER_HEIGHT" \
    --output "$OUTPUT_DIR/${PROJECT_NAME}_render-bottom.png"

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_render-bottom.png" ]] || {
    echo "ERROR: Bottom render was not created!"
    exit 1
}

###############################################################################
# Isometric render
###############################################################################

ISO_ROTATION="315,0,45"

run_kicad_cmd "Exporting isometric render" \
    $KICAD_CLI pcb render "$PCB" \
    --side top \
    --quality "$RENDER_QUALITY" \
    --width "$RENDER_WIDTH" \
    --height "$RENDER_HEIGHT" \
    --rotate "$ISO_ROTATION" \
    --output "$OUTPUT_DIR/${PROJECT_NAME}_render-iso.png"

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_render-iso.png" ]] || {
    echo "ERROR: Isometric render was not created!"
    exit 1
}

###############################################################################
# Drill + map
###############################################################################

run_kicad_cmd "Exporting drill files" \
    $KICAD_CLI pcb export drill "$PCB" \
    --output "$OUTPUT_DIR/drill" \
    --format excellon \
    --drill-origin absolute \
    --generate-map \
    --map-format pdf

if compgen -G "$OUTPUT_DIR/drill/*.pdf" > /dev/null; then
    MAPPDF=$(ls "$OUTPUT_DIR/drill/"*.pdf | head -n 1)
    mv "$MAPPDF" "$OUTPUT_DIR/drill/${PROJECT_NAME}_drill-map.pdf"
fi

[[ -f "$OUTPUT_DIR/drill/${PROJECT_NAME}_drill-map.pdf" ]] || {
    echo "ERROR: Drill map PDF was not created!"
    exit 1
}

###############################################################################
# STEP model
###############################################################################

run_kicad_cmd "Exporting STEP model" \
    $KICAD_CLI pcb export step "$PCB" \
    --output "$OUTPUT_DIR/${PROJECT_NAME}_board.step" \
    --force

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_board.step" ]] || {
    echo "ERROR: STEP model was not created!"
    exit 1
}

###############################################################################
# XY placement
###############################################################################

run_kicad_cmd "Exporting placement CSV" \
    $KICAD_CLI pcb export pos "$PCB" \
    --output "$OUTPUT_DIR/${PROJECT_NAME}_placement.csv" \
    --side both \
    --format csv \
    --units mm \
    --use-drill-file-origin \
    --exclude-dnp

sed -i '1s/Ref,Val,Package,PosX,PosY,Rot,Side/Designator,Val,Package,"Mid X","Mid Y",Rotation,Layer/' "$OUTPUT_DIR/${PROJECT_NAME}_placement.csv"

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_placement.csv" ]] || {
    echo "ERROR: Placement CSV was not created!"
    exit 1
}

###############################################################################
# BOM (KiCad CLI)
###############################################################################

run_kicad_cmd "Exporting BOM CSV" \
    $KICAD_CLI sch export bom "$SCHEMATIC" \
    --fields 'Reference,Value,MPN,Footprint,${QUANTITY}' \
    --labels 'Designator, Comment, MPN, Footprint, Quantity' \
    --exclude-dnp \
    --group-by "Value" \
    --ref-range-delimiter "" \
    --output "$OUTPUT_DIR/${PROJECT_NAME}_bom.csv"

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_bom.csv" ]] || {
    echo "ERROR: BOM CSV was not created!"
    exit 1
}

# Fix oversized Designator fields (>2048 chars) for JLCPCB/PCBWay compatibility
gawk -i inplace -F',' 'NR==1 {print; next}
{
  # Extract first quoted field (Designator) and everything after it
  if (match($0, /^"([^"]*)",(.*)$/, a)) {
    refs_str = a[1]          # Raw designator list without quotes
    rest = a[2]              # Everything after first field: ," Comment",...
    
    # Split into individual refs
    n = split(refs_str, refs, ",")
    
    chunk = ""
    for (i = 1; i <= n; i++) {
      test = (chunk == "" ? refs[i] : chunk "," refs[i])
      # Check if QUOTED length would exceed 2048 chars
      if (length("\"" test "\"") > 2048) {
        print "\"" chunk "\"," rest
        chunk = refs[i]
      } else {
        chunk = test
      }
    }
    if (chunk != "") print "\"" chunk "\"," rest
  } else {
    print  # Fallback for malformed lines
  }
}' "$OUTPUT_DIR/${PROJECT_NAME}_bom.csv"

###############################################################################
# Interactive HTML BOM with command-line flags
###############################################################################

echo "→ Generating Interactive HTML BOM"

# Detect KiCad Python (native first, then Flatpak)
KICAD_PYTHON=""
if python3 -c "import pcbnew" 2>/dev/null; then
    KICAD_PYTHON="python3"
elif [[ "$USE_FLATPAK" == true ]]; then
    KICAD_PYTHON="flatpak run --command=python3 org.kicad.KiCad"
fi

if [[ -z "$KICAD_PYTHON" ]]; then
    echo "⚠ Warning: Could not find KiCad Python with pcbnew, skipping Interactive HTML BOM"
else
    # Install InteractiveHtmlBom
    if [[ "$USE_FLATPAK" == true ]]; then
        flatpak run --command=python3 org.kicad.KiCad -m pip install --user InteractiveHtmlBom jsonschema --quiet 2>&1 || true
    else
        python3 -m pip install --user InteractiveHtmlBom jsonschema --quiet 2>&1 || true
    fi
    
    # Generate Interactive BOM with command-line flags
    echo "→ Running InteractiveHtmlBom generate_interactive_bom..."
    
    if INTERACTIVE_HTML_BOM_CLI_MODE=1 INTERACTIVE_HTML_BOM_NO_DISPLAY=1 \
        $KICAD_PYTHON -m InteractiveHtmlBom.generate_interactive_bom \
        --dest-dir "$OUTPUT_DIR" \
        --no-browser \
        --show-fields "Value,Footprint,MF,MPN" \
        --group-fields "Value,Footprint" \
        --normalize-field-case \
        --dnp-field "kicad_dnp" \
        --bom-view "left-right" \
        --layer-view "F" \
        --sort-order "C,R,L,D,U,Y,X,F,SW,A,~,HS,CNN,J,P,NT,MH" \
        --blacklist "FID*,MH*" \
        --include-tracks \
        "$PCB" 2>&1 | tee -a "$LOG_FILE"; then
        # Check if HTML was generated
        if find "$OUTPUT_DIR" -maxdepth 1 -name "*.html" | grep -q .; then
            echo "✓ Interactive BOM generated successfully"
        else
            echo "⚠ Interactive BOM: No HTML files generated"
        fi
    else
        echo "⚠ Warning: Interactive BOM generation failed (see log above)"
    fi
fi

###############################################################################
# Gerbers → ZIP (KiCad 9, JLCPCB-Compatible)
###############################################################################

run_kicad_cmd "Exporting Gerbers" \
    $KICAD_CLI pcb export gerbers "$PCB" \
    --output "$OUTPUT_DIR/gerbers" \
    --layers "$GERBER_LAYERS"

run_kicad_cmd "Exporting Drill Files (JLCPCB-compatible Excellon)" \
    $KICAD_CLI pcb export drill "$PCB" \
    --output "$OUTPUT_DIR/gerbers" \
    --format excellon \
    --drill-origin absolute \
    --excellon-zeros-format decimal \
    --excellon-units mm \
    --excellon-oval-format route

echo "→ Removing Gerber Job file (if present)"
rm -f "$OUTPUT_DIR/gerbers/"*.gbrjob

echo "→ Zipping Gerbers and Drill Files"
(
    cd "$OUTPUT_DIR/gerbers"
    zip -r "../${PROJECT_NAME}_gerbers.zip" . > /dev/null 2>&1
)
rm -rf "$OUTPUT_DIR/gerbers"

[[ -f "$OUTPUT_DIR/${PROJECT_NAME}_gerbers.zip" ]] || {
    echo "ERROR: Gerbers ZIP was not created!"
    exit 1
}

###############################################################################
# Report.txt
###############################################################################

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "→ Writing report.txt"

cat <<EOF > "$REPORT_FILE"
KiCad Export Report
===================

Project: $PROJECT_NAME
Run at: $RUN_DATETIME
Duration: ${DURATION}s
KiCad Type: $([ "$USE_FLATPAK" = true ] && echo "Flatpak" || echo "Native")

Render settings:
  Quality: $RENDER_QUALITY
  Resolution: ${RENDER_WIDTH}x${RENDER_HEIGHT}
  Isometric rotation: $ISO_ROTATION

Gerber layers:
  $GERBER_LAYERS

Drill:
  Format: Excellon
  Map: PDF

Placement:
  Format: CSV
  Units: mm
  Side: both

Interactive BOM:
  Fields: Value, Footprint, MF, MPN
  Grouped by: Value, Footprint
  DNP filtering: Enabled (kicad_dnp field)
  Layout: left-right
  Layer view: Front

Generated files:
$(ls -1 "$OUTPUT_DIR")
EOF

###############################################################################
# Done
###############################################################################

echo ""
echo "✓ All artifacts generated in: $OUTPUT_DIR"
echo "✓ Build log: $LOG_FILE"
ls -R "$OUTPUT_DIR"
