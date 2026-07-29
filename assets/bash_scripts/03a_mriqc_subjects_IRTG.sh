#!/bin/bash

# ------------------------------------------------------------------------
# Script: Step 3a - Check each subject's data quality with MRIQC 25.0.0rc0
# ------------------------------------------------------------------------
# This script was created by Ann-Christin Kimmig and reviewed by Bernd Kardatzki for the IRTG2804 projects.
# It runs MRIQC on a given dataset using MRIQC 25.0.0rc0 in Apptainer/Singularity
#
# The script: 
# - Creates output for each subject with data quality measures. Additionally, logfiles of processing are produced. /log_mriqc contains a short overview of settings and any warnings or errors.
# - Performs multi-core (NPROCS) and multi-threaded (OMP_THREADS) processing for efficient data analysis (please adjust, if needed).
# - NPROC and OMP_THREADS can be set via the command line before running this script using: "export NPROCS=X" and "export OMP_THREADS=X".
#   alternatively it can be set by options in the script (see below). Rule of thumb: Maximal number of processes (OMP_THREADS) should not exceed NCOR
#   of machine you are on. But beware, you are probably not the only person using this machine, so check before altering defaults.
#
# How to use:
# For helper function explaining possible arguments/parameters for processing: ./03a_mriqc_subjects_IRTG.sh -h
# For processing enter in command line: ./03a_mriqc_subjects_IRTG.sh "/path/to/input_dir"
# - If you want to adjust default values of NPROCS and OMP_THREADS, use this with X being the numbers you want to adjust to: ./03a_mriqc_subjects_IRTG.sh -n X -t X "/path/to/input_dir"
# - If you want to define a different output directory from the default enter in command line: ./03a_mriqc_subjects_IRTG.sh -o "/path/to/output_dir" "/path/to/input_dir"
# - If you want to run MRIQC for specific VPs only to not overload machine, enter in command line: ./03a_mriqc_subjects_IRTG.sh -v "/path/to/vpn.txt" "/path/to/input_dir"
# Of course different optional arguments can also be combined, see helper function.
#
# --------------------------------------------------------------------
# Contact: ann-christin.kimmig@med.uni-tuebingen.de
# If you have any questions or suggested changes, please reach out.
# --------------------------------------------------------------------

# Ensure the script is executed, not sourced
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && { echo "Please don't source but execute me!"; return; }

# Define Apptainer/Singularity path
APPTAINER_IMG="/nic/sw/IRTG/sif/mriqc_25.0.0rc0.sif"

# Default values (can be overridden)
: ${NPROCS:=16}
: ${OMP_THREADS:=4}
: ${MEM_GB:=16}

# Function to display usage instructions when called from the command line
function Usage(){
    echo
    echo "Usage: ${0##*/} [-n NPROCS] [-t OMP_THREADS] [-o OUTPUT_DIR] [-v VPN_FILE] INPUT_DIR"
	echo
    echo "  -n NPROCS       Number of processes (default: $NPROCS)"
    echo "  -t OMP_THREADS  Number of threads per process (default: $OMP_THREADS)"
    echo "                  Alternatively, NPROC, OMP_THREADS and MEM_GB can be set via the command line before running this script using: 'export NPROCS=X' and 'export OMP_THREADS=X'"
    echo "  -o OUTPUT_DIR   Output directory (default: <INPUT_DIR>/derivatives/mriqc)"
    echo "  -v VPN_FILE     File with participants to be processed (optional, e.g. \"/p/irtg/IRTGXX/00_Codes_IRTGXX/vpn_lists/vpn1.txt)\", default: processes all unprocessed participants"
    echo
	echo "INPUT_DIR is mandatory and used as base folder for output and logfiles (default: <INPUT_DIR>/derivatives/mriqc/logs_mriqc)."
    echo "Recommended INPUT_DIR is \"/p/irtg/IRTGXX/01_BIDS_IRTGXX\""
    echo "$1"
}

# Parse command-line arguments
while getopts ":hn:t:o:v:" OPT; do
    case $OPT in
        # Option -h: Show usage and exit
        h ) Usage; exit 0 ;;
        # Option -n: Adapt number of processes
        n ) NPROCS="$OPTARG" ;;
        # Option -t: Adapt number of threads per process
        t ) OMP_THREADS="$OPTARG" ;;
        # Option -o: Use alternative output directory
        o ) OUTPUT_DIR="$OPTARG" ;;
        # Option -v: add vpn_list to only process specific VPs
        v ) VPN_FILE="$OPTARG" ;;
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
WORK_DIR="$INPUT_DIR/derivatives/work/mriqc_work"  # Needs to be accessible, otherwise mriqc will reprocess all subjects
LOG_DIR="$OUTPUT_DIR/logs/logs_subjects"

# Create necessary directories
mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR"

# Log file setup
LOGFILE="$LOG_DIR/mriqc_errlog_$(date +"%Y-%m-%d-%H-%M")_$$.txt"
# Logging errors and warnings on their own for overview but ignoring the loading bar
exec 2> >(grep -Ev 'it/s]' | tee -a "$LOGFILE")

# Log settings, include this on top of error and warnings
echo "MRIQC Processing Log - $(date)" | tee -a "$LOGFILE"
echo "Input directory: $INPUT_DIR" | tee -a "$LOGFILE"
echo "Output directory: $OUTPUT_DIR" | tee -a "$LOGFILE"
echo "Working directory: $WORK_DIR" | tee -a "$LOGFILE"
echo "Apptainer/Singularity image: $APPTAINER_IMG" | tee -a "$LOGFILE"
echo "Number of processes (NPROCS): $NPROCS" | tee -a "$LOGFILE"
echo "Threads per process (OMP_THREADS): $OMP_THREADS" | tee -a "$LOGFILE"
echo

# Check if vpn.txt exists and read subject list
PARTICIPANT_LABELS=()

if [[ -f "$VPN_FILE" ]]; then
    # Check if the file contains Windows-style line endings before converting
    if grep -q $'\r' "$VPN_FILE"; then
        if command -v dos2unix &> /dev/null; then
            dos2unix "$VPN_FILE"
        else
            echo "Warning: dos2unix not found. Attempting manual conversion."
            sed -i 's/\r$//' "$VPN_FILE"
        fi
    fi
    # Read file into array
    mapfile -t PARTICIPANT_LABELS < "$VPN_FILE"
    # Print participants
    echo "Using participants from $VPN_FILE: ${PARTICIPANT_LABELS[@]}"
fi

# Join all labels into a single string (space-separated)
PARTICIPANT_LABELS_STR="${PARTICIPANT_LABELS[@]}"

echo "Running MRIQC on all (selected) subjects"

# Process each subject in the input directory with MRIQC using Apptaineroptional 
# optional: --participant-label, processes only participants in vpn_list.txt, if provided
# --no-sub: Prevents report uploads to MRIQC's online dashboard, -v: some more detailed logging
# --verbose-reports: Saves additional processing reports

apptainer run \
        -B "$WORK_DIR:/work_dir" \
        -B "$INPUT_DIR:/input_dir" \
        -B "$OUTPUT_DIR:/output_dir" \
        "$APPTAINER_IMG" \
        "/input_dir" \
        "/output_dir" \
        participant \
        ${PARTICIPANT_LABELS_STR:+--participant-label "$PARTICIPANT_LABELS_STR"} \
        --nprocs "$NPROCS" \
        --omp-nthreads "$OMP_THREADS" \
        --mem_gb "$MEM_GB" \
        --no-sub \
        -v \
        --verbose-reports \
        --work-dir "/work_dir"

echo "Finished processing all subjects" >> "$LOGFILE"
