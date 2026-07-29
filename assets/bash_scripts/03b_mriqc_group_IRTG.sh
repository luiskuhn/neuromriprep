#!/bin/bash

# ---------------------------------------------------------------------------
# Script: Step 3b - Create group statistics data quality with MRIQC 25.0.0rc0
# ---------------------------------------------------------------------------
# This script was created by Ann-Christin Kimmig and reviewed by Bernd Kardatzki for the IRTG2804 projects.
# It runs MRIQC on a given dataset using MRIQC 25.0.0rc0 in Apptainer/Singularity
#
# The script: 
# - Creates a group overview and statistics of data quality. Helps to identify outliers.
#
# How to use:
# For helper function explaining possible arguments/parameters for processing: ./03b_mriqc_group_IRTG.sh -h
# For processing enter in command line: ./03b_mriqc_group_IRTG.sh "/path/to/input_dir"
# - If you want to define a different output directory from the default enter in command line: ./03b_mriqc_group_IRTG.sh -o "/path/to/output_dir" "/path/to/input_dir"
#
# --------------------------------------------------------------------
# Contact: ann-christin.kimmig@med.uni-tuebingen.de
# If you have any questions or suggested changes, please reach out.
# --------------------------------------------------------------------

# Ensure the script is executed, not sourced
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && { echo "Please don't source but execute me !"; return; }

# Define Apptainer/Singularity image
APPTAINER_IMG="/nic/sw/IRTG/sif/mriqc_25.0.0rc0.sif"  # Path to the MRIQC Singularity image
#APPTAINER_IMG="$IRTG/sif/mriqc.sif"  # more generic alternative, however less safe if important tha always same version is used

# Default values (can be overridden)
: ${MEM_GB:=4}

# Function to display usage instructions when called from the command line
function Usage(){
    echo
    echo "Usage: ${0##*/} [-o OUTPUT_DIR] INPUT_DIR"
	echo
    echo "If needed, other MEM_GB (default: $MEM_GB) can be set via the command line before running this script using: 'export MEM_GB=X'"
    echo "  -o OUTPUT_DIR   Alternative output directory (default: <INPUT_DIR>/derivatives/mriqc)"
    echo
	echo "INPUT_DIR is mandatory and used as base folder for output and logfiles (default: <INPUT_DIR>/derivatives/mriqc/logs_mriqc)."
    echo "Recommended INPUT_DIR is \"/p/irtg/IRTGXX/01_BIDS_IRTGXX\""
    echo "$1"
}

# Parse command-line arguments
while getopts ":ho:" OPT; do
    case $OPT in
        # Option -h: Show usage and exit
        h ) Usage; exit 0 ;;
        # Option -o: Use alternative output directory
        o ) OUTPUT_DIR="$OPTARG" ;;
        # Catch invalid options or missing arguments
        ? ) echo "${0##*/}: unexpected option \"-$OPTARG\" or missing argument"; exit 1 ;;
    esac
done
# Shift arguments to move past the options
shift $((OPTIND - 1))

# Ensure INPUT_DIR is provided
if [ $# -lt 1 ]; then
    Usage "Need exactly one folder name as the INPUT_DIR argument!"
    exit 1
else
	# Set INPUT_DIR to the absolute path of the given argument
    INPUT_DIR="$(realpath $1)"
	echo "Processing input directory: $INPUT_DIR"
fi

# Check if INPUT_DIR exists
[[ -d $INPUT_DIR ]] || { echo "${0##*/}: $INPUT_DIR not found"; exit 1; }

# Define paths
: "${OUTPUT_DIR:="$INPUT_DIR/derivatives/mriqc"}"
WORK_DIR="$INPUT_DIR/derivatives/work/mriqc_group_work"  # Needs to be accessible, otherwise mriqc will try to generate a work directory in folder containing this script
LOG_DIR="$OUTPUT_DIR/logs/logs_group"

# Create necessary directories
mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR"

# Log file for saving output
LOGFILE="$LOG_DIR/mriqc_errlog_$(date +"%Y-%m-%d-%H-%M").txt"
echo "MRIQC Processing Log Group - $(date)" > "$LOGFILE"  # Initialize log file with a timestamp

# Process each subject in the input directory with singularity command to creat group output, --no-sub: Prevents report uploads to MRIQC's online dashboard
apptainer run \
    -B "$WORK_DIR:/work_dir" \
    -B "$INPUT_DIR:/input_dir" \
    -B "$OUTPUT_DIR:/output_dir" \
    "$APPTAINER_IMG" \
    "/input_dir" \
    "/output_dir" \
    group \
    --mem_gb "$MEM_GB" \
    --no-sub \
    --work-dir "/work_dir" \
    2>&1 | grep -i -e "warning" -e "error" | tee -a "$LOGFILE"

# Final message in the log file
echo "MRIQC group processing completed at $(date)" >> "$LOGFILE"
