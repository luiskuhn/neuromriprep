#!/bin/bash

# ----------------------------------------------------------------------
# Script: Step 4 - Run fMRIprep 24.1.1 on BIDS dataset
# ----------------------------------------------------------------------
# This script was created by Ann-Christin Kimmig and reviewed by Bernd Kardatzki for the IRTG2804 projects.
# It runs fMRIprep on a given BIDS-dataset using FMRIPREP 24.1.1 in Apptainer/Singularity.
# TEMPLATEFLOW_HOME is needed to retrieve output space maps, as internet access within clinic network is difficult, 
# so instead it refers to locally stored maps on the server.
# Make sure that you initialized this path once in your terminal, after that it will be saved for the future:
#  export TEMPLATEFLOW_HOME=/nic/sw/IRTG/templateflow
#  export APPTAINERENV_TEMPLATEFLOW_HOME=/templateflow
#
# The script: 
# - performs preprocessing using fMRIPrep 24.1.1, default settings do not include generation of unbiased T1w template over multiple runs,
#  for this enable -l, should be generally sufficient though if no longitudinal T1w analysis is planned with this data
# - can be run for specific participants, sessions and datatypes using vpn-lists and bids-filter-files
# - Note: fMRIPrep automatically skips participants that have already been preprocessed. To rerun processing for these participants, their output files must be deleted first.
#
# How to use:
# For helper function explaining possible arguments/parameters for processing: ./04_fmriprep_IRTG.sh -h
# For processing all subjects in dataset enter in command line: ./04_fmriprep_IRTG.sh "/path/to/input_dir"
# - if want to process spefific subjects: ./04_fmriprep_IRTG.sh -v "/path/to/vpn-list.txt" "/p/irtg/IRTGXX/01_BIDS_IRTGXX"
# - if want to process spefific sessions (shortcut type -f ses01 or -f ses02) and/or datatypes: ./04_fmriprep_IRTG.sh -f "/path/to/bids-filter-file.json" "/p/irtg/IRTGXX/01_BIDS_IRTGXX"
# - if want to do longitudinal T1w processing: ./04_fmriprep_IRTG.sh -l "/p/irtg/IRTGXX/01_BIDS_IRTGXX"
# - all flags can be used in combination if needed. For omp_threads adjustment or addition of output spaces (e.g. fsaverage): -t 16 -o "fsaverage"
#
# ------------------------------------------------------------------
# Contact: ann-christin.kimmig@med.uni-tuebingen.de
# If you have any questions or suggested changes, please reach out.
# ------------------------------------------------------------------

# Ensure the script is executed, not sourced
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && { echo "Please don't source but execute me!"; return; }

# Singularity and FreeSurfer settings
#WORK_DIR="$(mktemp -d /p/irtg/tmp/${USER}_IRTG.XXXXX)"
APPTAINER_IMG="/nic/sw/IRTG/sif/fmriprep_24.1.1.sif"
#APPTAINER_IMG="$IRTG/sif/fmriprep.sif"  # more generic and easier to change versions, but also less stable if all data needs same kind of processing
FREESURFER_PATH="/nic/sw/FreeSurfer"  # Path to Freesurfer folder to access the license file
FS_LICENSE="/nic/sw/FreeSurfer/license.txt"  # Path to FreeSurfer license file
FILTER_PATH_SES01="/nic/sw/IRTG/scripts/bids-filter-file/filter_ses01.json"
FILTER_PATH_SES02="/nic/sw/IRTG/scripts/bids-filter-file/filter_ses02.json"

# Default values (can be overridden)
: ${OMP_THREADS:=16}
#MEM_GB=8
#: ${NPROCS:=4}
RANDOM_SEED=13  # Set a random seed for reproducibility

# Function to display usage instructions when called from the command line
function Usage(){
    echo
    echo "Usage: ${0##*/} [-t OMP_THREADS] [-o OUTPUT_DIR] [-v VPN_FILE] [-f BIDS_FILTER] [-l LONGITUDINAL] [-s ADDITIONAL_OUTPUT_SPACES] INPUT_DIR"
    echo
    echo "  -t OMP_THREADS        Number of threads per process ($OMP_THREADS)"
    echo "  -o OUTPUT_DIR         Output directory (default: <INPUT_DIR>/derivatives/fmriprep)"
    echo "  -v VPN_FILE           File with participants to be processed (optional, e.g. \"/p/irtg/IRTGXX/00_Codes_IRTGXX/vpn_lists/vpn1.txt\"), default: processes all unprocessed participants"
    echo "  -f BIDS_FILTER        BIDS filter for selecting specific sessions and/or datatypes (optional). Either enter your file path or type \"ses01\" to only process first sesssion and \"ses02\" for second session"
    echo "  -l LONGITUDINAL       Flag to indicate whether to use longitudinal analysis (default: false, only relevant for anatomical analysis)"
    echo "  -s EXTRA SPACES       Additional output-spaces to MNI152NLin2009cAsym and MNI152NLin6Asym, can be entered as: -s \"fsaverage\""
    echo
    echo "INPUT_DIR is mandatory and used as base folder for output and logfiles (default: <INPUT_DIR>/derivatives/fmriprep/logs_fmriprep)."
    echo "Recommended INPUT_DIR is \"/p/irtg/IRTGXX/01_BIDS_IRTGXX\""
    echo "$1"
}

# Parsing input arguments
while getopts ":ht:o:v:f:ls:" OPT; do
    case $OPT in
        # Option -h: Show usage and exit		
        h ) Usage; exit 0 ;;
        # Option -t: Adapt number of threads per process
        t ) OMP_THREADS="$OPTARG" ;;
        # Option -o: Use alternative output directory
        o ) OUTPUT_DIR="$OPTARG" ;;
        # Option -v: Add vpn_list to only process specific VPs
        v ) VPN_FILE="$OPTARG" ;;
        # Option -b: Select only specific datatypes or sessions for the fmriprep run
        f ) BIDS_FILTER="$OPTARG" ;;
        # Option -l: Choose whether anatomical data should be analyzed longitudinally, producing output for each session
        l ) LONGITUDINAL_FLAG="--longitudinal" ;;
        # Option -s: Additional output spaces
        s ) ADDITIONAL_OUTPUT_SPACES="$OPTARG" ;;
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
: "${OUTPUT_DIR:="$INPUT_DIR/derivatives/fmriprep"}"
WORK_DIR="$INPUT_DIR/derivatives/work/fmriprep_work"
LOG_DIR="$OUTPUT_DIR/logs"

# Create necessary directories
mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR"

# Ensure TEMPLATEFLOW_HOME is set, if not use a (hopefully sufficient) fallback
if [ -z "$TEMPLATEFLOW_HOME" ]; then
    export TEMPLATEFLOW_HOME="$HOME/.cache/templateflow"
    echo "TEMPLATEFLOW_HOME was not set. Using default: \"$TEMPLATEFLOW_HOME\""
fi
# Teach fmriprep container to not use its own (almost empty) template repository
if [ -z $APPTAINERENV_TEMPLATEFLOW_HOME ]; then
    export APPTAINERENV_TEMPLATEFLOW_HOME=/templateflow
    echo "APPTAINERENV_TEMPLATEFLOW_HOME was not set. Setting to: \"$APPTAINERENV_TEMPLATEFLOW_HOME¸\""
fi

# Check if vpn.txt exists and read subject list
PARTICIPANT_LABELS=()

if [[ -f "$VPN_FILE" ]]; then
    # Check for Windows-style line endings before converting
    if grep -q $'\r' "$VPN_FILE"; then
        if command -v dos2unix &> /dev/null; then
            dos2unix "$VPN_FILE"
        else
            echo "Warning: dos2unix not found. Attempting manual conversion."
            sed -i 's/\r$//' "$VPN_FILE"
        fi
    fi
    # Read file into array and remove "sub-" prefix
    mapfile -t PARTICIPANT_LABELS < <(sed 's/^sub-//' "$VPN_FILE")
    echo "Using participants from $VPN_FILE: ${PARTICIPANT_LABELS[@]}"
else
    # Get the list of subjects from INPUT_DIR if no VPN file is provided
	mapfile -t PARTICIPANT_LABELS < <(find "$INPUT_DIR" -maxdepth 1 -type d -name "sub-*" | sed 's|^.*/sub-||')

    # Check if subjects were found
    if [ ${#PARTICIPANT_LABELS[@]} -eq 0 ]; then
        echo "Error: No subjects found in $INPUT_DIR. Check if the dataset is correctly structured."
        exit 1
    fi
    echo "Subjects found: ${PARTICIPANT_LABELS[@]}"
fi

# Convert array to space-separated string
PARTICIPANT_LABELS_STR="${PARTICIPANT_LABELS[@]}"


# Handle BIDS_FILTER based on session
case "$BIDS_FILTER" in
    "ses01") BIDS_FILTER="$FILTER_PATH_SES01" ;;
    "ses02") BIDS_FILTER="$FILTER_PATH_SES02" ;;
esac


# Start loop for fMRIprep
echo "Starting fMRIPrep..."

########################################################
# Run fmriprep flexibly for different flags
########################################################

# Loop over each subject/participant label (you can define PARTICIPANT_LABELS_STR with your list)
for subject in $PARTICIPANT_LABELS_STR; do
    # Display the participant label being processed
    echo "Processing participant: $subject"
    
    # Run the Apptainer command for each subject with the dynamic output spaces
    apptainer run --cleanenv \
        -B "$TEMPLATEFLOW_HOME:$APPTAINERENV_TEMPLATEFLOW_HOME" \
        -B "$WORK_DIR:/work_dir" \
        -B "$INPUT_DIR:/input_dir" \
        -B "$OUTPUT_DIR:/output_dir" \
        -B "$FREESURFER_PATH:$FREESURFER_PATH" \
		${BIDS_FILTER:+-B "$BIDS_FILTER:/bids_filter.json:ro"} \
        "$APPTAINER_IMG" \
        "/input_dir" \
        "/output_dir" \
		--notrack \
        participant \
        ${PARTICIPANT_LABELS_STR:+--participant-label $subject} \
        $LONGITUDINAL_FLAG \
        ${BIDS_FILTER:+--bids-filter-file /bids_filter.json} \
        --fs-license-file "$FS_LICENSE" \
        --skip_bids_validation \
        --omp-nthreads "$OMP_THREADS" \
        --random-seed "$RANDOM_SEED" \
        --skull-strip-fixed-seed \
        --output-spaces MNI152NLin2009cAsym MNI152NLin6Asym${ADDITIONAL_OUTPUT_SPACES:+ $ADDITIONAL_OUTPUT_SPACES} \
        --work-dir "/work_dir" \
        1> >(tee -a "$LOG_DIR/sub-${subject}_$(date +"%Y-%m-%d-%H-%M")_out.log") \
        2> >(tee >(grep -i -e "warning" -e "error" >> "$LOG_DIR/sub-${subject}_$(date +"%Y-%m-%d-%H-%M")_err.log") >&2)
done
