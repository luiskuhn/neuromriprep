#!/bin/bash
#
# ------------------------------------------------------------------
# Script: Step 2 - BIDS Validation Script for IRTG2804
# ------------------------------------------------------------------
# This script was created by Ann-Christin Kimmig for the IRTG2804 projects and reviewed by Bernd Kardatzki.
# It runs the BIDS validator 1.14.13 on a given BIDS dataset.
#
# The script:
# - ensures that the .bidsignore file is present in the input directory,
# - updates .bidsorgnore with the necessary items from the IGNORE_LIST,
# - deletes items from .bidsignore, if added to the DELETE_LIST 
#
# How to use:
# For helper function explaining possible arguments/parameters for processing: ./02_validatebids_IRTG.sh -h
# For processing enter in command line: ./02_validatebids_IRTG.sh "/path/to/input_dir"
# - if want to add items from .bidsignore: ./02_validatebids_IRTG.sh -i "/path/to/ignore1,/path/to/ignore2,*example.json" "/p/irtg/IRTGXX/01_BIDS_IRTGXX"
# - if want to add remove from .bidsignore: ./02_validatebids_IRTG.sh -d "/path/to/delete1,*example.json" "/p/irtg/IRTGXX/01_BIDS_IRTGXX"
#
# ------------------------------------------------------------------
# Contact: ann-christin.kimmig@med.uni-tuebingen.de
# If you have any questions or suggested changes, please reach out.
# ------------------------------------------------------------------

# we want to be called directly by name to be able to call "exit" without shutting down our shell
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && { echo "Please don't source but execute me !"; return; }

# Define Apptainer (singularity) image for BIDS validator
APPTAINER_IMG="/nic/sw/IRTG/sif/validator_1.14.13.sif"

[[ -f $APPTAINER_IMG ]] || { echo "$APPTAINER_IMG not found!"; exit 1; }

# Default ignore list
IGNORE_LIST=("tmp_dcm2bids/" "logs_dcm2bids/" "sourcedata/" "*_epi.bval" "*_epi.bvec")
DELETE_LIST=()

# Function to display usage instructions when called from the command line
function Usage(){
    echo
    echo "Usage: ${0##*/} [-i ADDITIONAL_IGNORE_LIST] [-d DELETE_LIST] INPUT_DIR"
    echo
    echo "The script will create a .bidsignore file, when not present, but will always check that it contains: tmp_dcm2bids/ logs_dcm2bids/ sourcedata/ *_epi.bval *_epi.bvec."
    echo "-i ADDITIONAL_IGNORE_LIST: Comma-separated list (e.g., \"/path/to/ignore1,/path/to/ignore2,*example.json\") of paths to be ignored in .bidsignore (optional)."
    echo "-d DELETE_LIST: Comma-separated list (e.g., \"/path/to/deletefromlist1,/path/to/deletefromlist2,*example.json\") of paths to be deleted from .bidsignore (optional)."
    echo
    echo "INPUT_DIR is mandatory and used as base folder for input and logs - saved into /logs_dcm2bids."
    echo "Recommended INPUT_DIR is \"/p/irtg/IRTGXX/01_BIDS_IRTGXX\""
    echo "$1"
}

# Parse command line parameters
while getopts ":hi:d:" OPT; do
    case $OPT in
        # Option -h: Show usage and exit with error
        h ) Usage; exit 1 ;;
        # Option -i: Set list of paths, files etc which should be on .bidsignore list
        i ) ADDITIONAL_IGNORE_LIST=(${OPTARG//,/ }) ;;  # Initialize ADDITIONAL_IGNORE_LIST, onvert comma-separated values to array
        # Option -d: Delete list of paths, files etc which should be REMOVED from .bidsignore list
        d ) DELETE_LIST=(${OPTARG//,/ }) ;;  # Convert comma-separated values to array
        # Catch invalid options or missing arguments
        ? ) echo "${0##*/}: unexpected option \"-$OPTARG\" or missing argument"; exit 1 ;;
    esac
done
# Shift arguments to move past the options
shift $((OPTIND - 1))

# Ensure at least one argument (INPUT_DIR) is provided
if [ $# -lt 1 ]; then
    Usage "Need exactly one folder name as the INPUT_DIR argument!"
    exit 1
else
    # Set INPUT_DIR to the absolute path of the given argument
    INPUT_DIR="$(realpath $1)"
    echo "Processing input directory: $INPUT_DIR"
fi

# Check if INPUT_DIR is a valid directory
[[ -d $INPUT_DIR ]] || { echo "$INPUT_DIR not found!"; exit 1; }

# Append additional ignore items if provided
if [ -n "$ADDITIONAL_IGNORE_LIST" ]; then
    IGNORE_LIST+=("${ADDITIONAL_IGNORE_LIST[@]}")
fi

# Bind LOG_DIR to INPUT_DIR
LOG_DIR="${INPUT_DIR}/logs_dcm2bids"
# Ensure output and log directory exist, only creates them if not already there
mkdir -p "$LOG_DIR"
# Create logfile
LOGFILE="${LOG_DIR}/bidsvalidation_log_$(date +"%Y-%m-%d-%H-%M").txt"

# Start logging for BIDS validation
echo "### Starting BIDS validation process ###" | tee -a "$LOGFILE"
echo "Timestamp: $(date +"%Y-%m-%d %H:%M:%S")" | tee -a "$LOGFILE"
echo "Input directory: $INPUT_DIR" | tee -a "$LOGFILE"
echo "Apptainer/Singularity image: $APPTAINER_IMG" | tee -a "$LOGFILE"
echo | tee -a "$LOGFILE"

# Ensure the .bidsignore file exists
if [ ! -f "$INPUT_DIR/.bidsignore" ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") - .bidsignore file not found. Creating a new one..." | tee -a "$LOGFILE"
    touch "$INPUT_DIR/.bidsignore"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - .bidsignore file created." | tee -a "$LOGFILE"
fi

# Print initial content of .bidsignore
echo "$(date +"%Y-%m-%d %H:%M:%S") - Initial .bidsignore content:" | tee -a "$LOGFILE"
cat "$INPUT_DIR/.bidsignore" | tee -a "$LOGFILE"
echo | tee -a "$LOGFILE"

# Ensure all IGNORE_LIST entries are in .bidsignore
for ITEM in "${IGNORE_LIST[@]}"; do
    if ! grep -Fxq "$ITEM" "$INPUT_DIR/.bidsignore"; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Adding '$ITEM' to .bidsignore..." | tee -a "$LOGFILE"
        echo "$ITEM" >> "$INPUT_DIR/.bidsignore"
    fi
done

# Remove unwanted entries in DELETE_LIST
for ITEM in "${DELETE_LIST[@]}"; do
    if grep -Fxq "$ITEM" "$INPUT_DIR/.bidsignore"; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Removing '$ITEM' from .bidsignore..." | tee -a "$LOGFILE"
        sed -i "/^$ITEM$/d" "$INPUT_DIR/.bidsignore"
    fi
done

# Print updated .bidsignore content
echo "$(date +"%Y-%m-%d %H:%M:%S") - Final .bidsignore list:" | tee -a "$LOGFILE"
cat "$INPUT_DIR/.bidsignore" | tee -a "$LOGFILE"
echo | tee -a "$LOGFILE"

echo "### Running BIDS Validator ###" | tee -a "$LOGFILE"


# Run BIDS validator using Singularity and save the log
apptainer run --cleanenv \
	  -B "$INPUT_DIR:/input_dir" \
	  "$APPTAINER_IMG" \
	  "/input_dir" \
	  --verbose 2>&1 | tee -a "$LOGFILE"

# Inform user that the validation log has been saved
echo "BIDS validation log saved at $LOGFILE"