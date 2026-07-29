#!/bin/bash
# ----------------------------------------------------------------------
# Script: Step 5 - Run PyDeface 2.0.0 on BIDS dataset
# ----------------------------------------------------------------------
# This script was created by Ann-Christin Kimmig (and Fani Lohrmann) for the IRTG2804 projects.
# It runs PyDeface on a given dataset using pydeface_2.0.0 in Apptainer/Singularity
#
# The script: 
# - Uses the NIfTI format anatomical scans in the 'anat' subfolder of a BIDsed dataset
# - Creates: - the defaced anatomical NIfTIs (defaced_*.nii.gz) of each subject/session. 
# 			 - logfiles in 'INPUT_DIR/derivatives/deface/logs' containing a short overview of settings and any warnings or errors.
# - Performs multi-threaded (OMP_THREADS) processing for efficient data analysis (please adjust, if needed).
# - OMP_THREADS can be set via the command line before running this script using: "export OMP_THREADS=X".
#   alternatively it can be set by options in the script (see below). Rule of thumb: Maximal number of processes (OMP_THREADS) should not exceed NCOR
#   of machine you are on. But beware, you are probably not the only person using this machine, so check before altering defaults.
#
# How to use:
# For helper function explaining possible arguments/parameters for processing: ./05_deface_subjects_IRTG.sh -h
# For processing enter in command line: ./05_deface_subjects_IRTG.sh "/path/to/input_dir"
# - If you want to adjust default values of OMP_THREADS, use this with X being the numbers you want to adjust to: ./05_deface_subjects_IRTG.sh -t X "/path/to/input_dir"
# - If you want to define a different output directory from the default enter in command line: ./05_deface_subjects_IRTG.sh -o "/path/to/output_dir" "/path/to/input_dir"
# - If you want to run PyDeface for specific VPs only to not overload machine, enter in command line: ./05_deface_subjects_IRTG.sh -v "/path/to/vpn.txt" "/path/to/input_dir"
# Of course different optional arguments can also be combined, see helper function.
#
# ------------------------------------------------------------------
# Contact: ann-christin.kimmig@med.uni-tuebingen.de
# If you have any questions or suggested changes, please reach out.
# ------------------------------------------------------------------

# Ensure the script is executed, not sourced
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && { echo "Please don't source but execute me!"; return; }

# Singularity and FreeSurfer settings
APPTAINER_IMG="/nic/sw/IRTG/sif/pydeface_2.0.0.sif" 

# Default values (can be overridden)
: ${OMP_THREADS:=8}
#MEM_GB=8
#: ${NPROCS:=4}
RANDOM_SEED=13  # Set a random seed for reproducibility

# Function to display usage instructions when called from the command line
function Usage(){
    echo
    echo "Usage: ${0##*/} [-t OMP_THREADS] [-o OUTPUT_DIR] [-v VPN_FILE] INPUT_DIR"
    echo
    echo "  -t OMP_THREADS        Number of threads per process ($OMP_THREADS)"
    echo "  -o OUTPUT_DIR         Output directory (default: <INPUT_DIR>/derivatives/pydeface)"
    echo "  -v VPN_FILE           File with participants to be processed (optional, e.g. \"/p/irtg/IRTGXX/00_Codes_IRTGXX/vpn_lists/vpn1.txt\"), default: processes all unprocessed participants"
    echo
    echo "INPUT_DIR is mandatory and used as base folder for output and logfiles (default: <INPUT_DIR>/derivatives/pydeface/logs)."
    echo "Recommended INPUT_DIR is \"/p/irtg/IRTGXX/01_BIDS_IRTGXX\""
    echo "$1"
}

# Parsing input arguments ":ht:o:v:f:ls:"
while getopts ":ht:o:v:" OPT; do
    case $OPT in
        # Option -h: Show usage and exit		
        h ) Usage; exit 0 ;;
        # Option -t: Adapt number of threads per process
        t ) OMP_THREADS="$OPTARG" ;;
        # Option -o: Use alternative output directory
        o ) OUTPUT_DIR="$OPTARG" ;;
        # Option -v: Add vpn_list to only process specific VPs
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
: "${OUTPUT_DIR:="$INPUT_DIR/derivatives/pydeface"}"
#WORK_DIR="$INPUT_DIR/derivatives/workdeface_work"
LOG_DIR="$OUTPUT_DIR/logs"

# Create necessary directories
mkdir -p "$OUTPUT_DIR" "$LOG_DIR" 

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

# Start loop for fMRIprep
echo "Starting PyDeface..."

########################################################
# Run pydeface flexibly for different flags
########################################################

# Loop over each subject/participant label (you can define PARTICIPANT_LABELS_STR with your list)

for subject in $PARTICIPANT_LABELS_STR; do
    subject_dir="$INPUT_DIR/sub-${subject}"
    [[ -d "$subject_dir" ]] || { echo "Warning: subject $subject not found in $INPUT_DIR"; continue; }

    echo "Processing participant: $subject_dir"

    for session_dir in "$subject_dir"/ses-*; do
         echo "Processing session: $session_dir"
         [[ -d "${session_dir}/anat" ]] || continue

         anat_dir="${session_dir}/anat"
         for nifti_file in "$anat_dir"/*.nii.gz; do
              output_file_dir="${OUTPUT_DIR}/$(basename "$subject_dir")/$(basename "$session_dir")/anat"
              mkdir -p "$output_file_dir"

              singularity run \
                  --bind "$session_dir:/input" \
                  --bind "$output_file_dir:/output" \
                  "$APPTAINER_IMG" \
                  pydeface "/input/anat/$(basename "$nifti_file")" \
                  --outfile "/output/$(basename "$nifti_file" .nii.gz)_defaced.nii.gz" \
                  1> >(tee -a "$LOG_DIR/$(basename "$subject_dir")_$(basename "$session_dir")_$(date +"%Y-%m-%d-%H-%M")_out.log") \
                  2> >(tee >(grep -i -e "warning" -e "error" >> "$LOG_DIR/$(basename "$subject_dir")_$(basename "$session_dir")_$(date +"%Y-%m-%d-%H-%M")_err.log") >&2)
         done
    done
done		    
