#!/bin/bash
#
# ------------------------------------------------------------------
# Script: Step 1 - DICOM to BIDS Conversion Script for IRTG2804
# ------------------------------------------------------------------
# This script was created by Ann-Christin Kimmig for the IRTG2804 projects and reviewed by Bernd Kardatzki.
# It automates the conversion of DICOM files to BIDS format using dcm2bids 3.2.0 with Apptainer.
#
# The script:
# - Defines a function to explain usage of 01_dcm2bids_IRTG.sh called from command line and parses the parameters. 
# - Iterates through subject session folders in the input directory.
# - Extracts subject and session information from folder names.
# - Modifies a JSON configuration file dynamically per session to adjust `B0FieldIdentifier` and `B0FieldSource`.
# - Runs `dcm2bids` using the modified configuration file.
# - Logs progress and errors.
# - After successful conversion, deletes BIDS incompliant json entries and files and moved ADC output to derivative folder.
#
# How to use:
# For helper function explaining possible arguments/parameters for processing: ./01_dcm2bids_IRTG.sh -h
# For processing enter in command line: ./01_dcm2bids_IRTG.sh "/path/to/input_dir"
# - By default, the script **skips** subjects that have already been processed. To force reprocessing, set "-f" after script name. This will overwrite existing outputs.
# - Alternative configuration file or output directories can be defined by "-c path/to/alternativeconfigfile" and "-o path/to/alternativeoutputfile" before the input path.
# If no alternative output directory is defined, it will automatically be saved in the parent folder (e.g., /p/irtg/IRTGXX/IRTGXX_BIDS) of the input_dir (e.g., "/p/irtg/IRTGXX/01_BIDS_IRTGXX/sourcedata")
#
# ------------------------------------------------------------------
# Contact: ann-christin.kimmig@med.uni-tuebingen.de
# If you have any questions or suggested changes, please reach out.
# ------------------------------------------------------------------

# We want to be called directly by name to be able to call "exit" without shutting down our shell
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && { echo "Please don't source but execute me !"; return; }

# Path to the Apptainer (Singularity) image used for processing  
APPTAINER_IMG="/nic/sw/IRTG/sif/dcm2bids_3.2.0.sif"
[[ -f $APPTAINER_IMG ]] || { echo "$APPTAINER_IMG not found!"; exit 1; }
# Preset defaults
FORCE_REPROCESSING=false 
CONFIG_PATH="/nic/sw/IRTG/scripts/config_dcm2bids"  # Path to folder containing the config file
CONFIG_NAME="config_IRTG.json" # This config file works for all IRTG projects and does not need to be altered

# Function to display usage instructions when called from the command line
function Usage(){
    echo
    echo "Usage: ${0##*/} [-f] [-c configfile] [-o OUTPUT_DIR] INPUT_DIR"
    echo "         -f : Force reprocessing (optional, default: no reprocessing of existing data)"
    echo "         -c : Specify an alternative configuration file path including filename"
	echo "              (optional, default: \"/nic/sw/IRTG/scripts/config_dcm2bids/config_IRTG.json\")"
    echo "         -o : Specify an alternative output directory (optional, default: parent directory of <INPUT_DIR>, one level up)"
    echo
    echo "INPUT_DIR is mandatory and defaults as base folder for input, output, logs and the default configfile."
	echo "Recommended INPUT_DIR is \"/p/irtg/IRTGXX/01_BIDS_IRTGXX/sourcedata\""
    echo "$1"
}

# Parse command line parameters
while getopts ":fhc:o:" OPT; do
    case $OPT in
        # Option -h: Show usage and exit with error
        h ) Usage; exit 1 ;;
        # Option -o: Set OUTPUT_DIR to the provided argument
        o ) OUTPUT_DIR=$OPTARG ; echo "Setting output directory: $OUTPUT_DIR"  ;;
        # Option -c: Validate the config file (if exists), and set CONFIG_PATH and CONFIG_NAME. 
        c ) 
            if [ -f "$OPTARG" ]; then
                CONFIG_PATH=$(dirname "$(realpath "$OPTARG")")
                CONFIG_NAME=$(basename "$(realpath "$OPTARG")")
                echo "Config file $OPTARG found: $CONFIG_NAME at $CONFIG_PATH"
            else
                echo "Config file $OPTARG not found!"; exit 1
            fi
            ;;
        # Option -f: Set FORCE_REPROCESSING flag to true
        f ) FORCE_REPROCESSING=true ; echo "Forcing reprocessing." ;;
        # Catch invalid options or missing arguments
        ? ) echo "${0##*/}: unexpected option \"-$OPTARG\" or missing argument"; exit 1 ;;
    esac
done
# Shift arguments to move past the options
shift $(($OPTIND - 1))

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

# Bind LOG_DIR to OUTPUT_DIR (and OUTPUT_DIR to INPUT_DIR if not explicitly set)
LOG_DIR="${OUTPUT_DIR:=${INPUT_DIR%/*}}/logs_dcm2bids"

# Ensure output and log directory exist, only creates them if not already there
mkdir -p "$OUTPUT_DIR" "$LOG_DIR" 

# Create logfile
LOGFILE="${LOG_DIR}/dcm2bids_log_$(date +"%Y-%m-%d-%H-%M").log"
echo "DCM2BIDS Conversion Log - $(date)" | tee -a "$LOGFILE"
echo "FORCE_REPROCESSING: $FORCE_REPROCESSING" | tee -a "$LOGFILE"
echo "INPUT_DIR: $INPUT_DIR" | tee -a "$LOGFILE"
echo "OUTPUT_DIR: $OUTPUT_DIR" | tee -a "$LOGFILE"
echo "CONFIG_PATH + CONFIG_FILE: $CONFIG_PATH/$CONFIG_FILE" | tee -a "$LOGFILE"
echo "" | tee -a "$LOGFILE"

#########################################################
# Loop through folders in input directory for processing
#########################################################

for folder in "$INPUT_DIR"/*; do
    echo "$folder"
    if [ -d "$folder" ]; then  
        subject=$(basename "$folder" | cut -d '_' -f 2)
        sesStr=$(basename "$folder" | cut -d '_' -f 3)
        ses=$(echo "$sesStr" | grep -oP '(?<=S)\d+')

        [ -z "$ses" ] && ses="01"
        session_label="ses-$(printf '%02d' "$ses")"
        echo "Processing participant: sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
		
		# Session-specific config files created for correct assignment of fmaps to bold using B0FieldSource and B0FieldIdentifier
        temp_config="$CONFIG_PATH/$CONFIG_NAME"
        modified_config="$CONFIG_PATH/modified_IRTG_${session_label}_config.json"  # One config per session

        # Ensure modified config is only created if it does not already exist
        if [ ! -f "$modified_config" ]; then
            echo "Creating modified config for $session_label..."

            if ! jq '.descriptions |= map(
                if .sidecar_changes?.B0FieldIdentifier? != null and (.sidecar_changes.B0FieldIdentifier | type == "string") and (.sidecar_changes.B0FieldIdentifier | test("_fmap"))
                then .sidecar_changes.B0FieldIdentifier += "_'"$session_label"'"
                else . end |
                if .sidecar_changes?.B0FieldSource? != null and (.sidecar_changes.B0FieldSource | type == "string") and (.sidecar_changes.B0FieldSource | test("_fmap"))
                then .sidecar_changes.B0FieldSource += "_'"$session_label"'"
                elif .sidecar_changes?.B0FieldSource? != null and (.sidecar_changes.B0FieldSource | type == "array") and (.sidecar_changes.B0FieldSource | all(. | type == "string"))
                then .sidecar_changes.B0FieldSource |= map(if . | test("_fmap") then . + "_'"$session_label"'" else . end)
                else . end
                )' "$temp_config" > "$modified_config"; then
                echo "Error: jq command failed for $session_label" | tee -a "$LOGFILE"
                exit 1  # Stop execution on jq failure
            fi

            # Ensure jq command worked and file is not empty
            if [ ! -s "$modified_config" ]; then
                echo "Error: modified config file is empty for $session_label" | tee -a "$LOGFILE"
                exit 1  # Stop execution if config is empty
            fi

            echo "Modified config created: $modified_config" | tee -a "$LOGFILE"
        else
            echo "Using existing modified config: $modified_config" | tee -a "$LOGFILE"
        fi

        # Conditionally add --force_dcm2bids if FORCE_REPROCESSING=true
        force_flag=""
        if [ "$FORCE_REPROCESSING" = true ]; then
            force_flag="--force_dcm2bids"
        fi

		########################################################
        # Run dcm2bids with the modified config file
		########################################################

        if ! apptainer run \
            -e --containall \
            -B "$folder:/dicoms:ro" \
            -B "$modified_config:/config.json:ro" \
            -B "$OUTPUT_DIR:/bids" \
            "$APPTAINER_IMG" \
            -d /dicoms -p "sub-${subject}" -s "$session_label" -c /config.json -o /bids $force_flag; then
            echo "Failed: ${subject}, session: $session_label" | tee -a "$LOGFILE"
        else
            echo "$(date +'%Y-%m-%d %H:%M:%S') - Success: ${subject}, session: $session_label" | tee -a "$LOGFILE"

            ##########################################################
            # If successful, do postprocessing to make BIDS compatible
            ##########################################################

            # Remove "AcquisitionDuration" from all generated _bold.json files to eliminate conflict between different fields (RepetitionTime, SliceTiming)
            bold_files=$(find "$OUTPUT_DIR/sub-${subject}/${session_label}/" -name "*_bold.json")

            if [ -n "$bold_files" ]; then
                # Use the bold_files variable to run jq/mv operations on all found files
                for file in $bold_files; do
                    if jq "del(.AcquisitionDuration)" "$file" > "$file.tmp" && mv "$file.tmp" "$file"; then
                        echo "Post-processing: Successfully removed 'AcquisitionDuration' from $file for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
                    else
                        echo "Error: Failed to process $file for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
                    fi
                done
            else
                echo "Warning: No _bold.json files found for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
            fi

            # Then delete and move dwi files to make BIDS compatible 
            # Define paths
            fmap_dir="$OUTPUT_DIR/sub-${subject}/${session_label}/fmap"
            dwi_dir="$OUTPUT_DIR/sub-${subject}/${session_label}/dwi"
            derivatives_dwi_adc="$OUTPUT_DIR/derivatives/dwi_ADC/sub-${subject}/${session_label}"

            # Move ADC files from /fmap and /dwi to derivatives/dwi_ADC
            mkdir -p "$derivatives_dwi_adc"

            # Find ADC files and move them if present, find sbref.bval and sbref.bvec and remove
            adc_files=$(find "$fmap_dir" "$dwi_dir" -type f -name "*ADC*")
            sbref_files=$(find "$dwi_dir" -type f \( -name "*sbref.bval" -o -name "*sbref.bvec" \))

            # Process ADC files
            if [ -n "$adc_files" ]; then
                if mv $adc_files "$derivatives_dwi_adc"; then
                    echo "Post-processing: Moved ADC files to derivatives for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
                else
                    echo "Error: ADC files were found but failed to move for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
                fi
            else
                echo "Warning: No ADC files found for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
            fi

            # Process sbref.bval and sbref.bvec files
            if [ -n "$sbref_files" ]; then
                if rm $sbref_files; then
                    echo "Post-processing: Deleted sbref.bval and sbref.bvec files for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
                else
                    echo "Error: Found sbref.bval and sbref.bvec files but failed to delete for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
                fi
            else
                echo "Warning: No sbref.bval or sbref.bvec files found for sub-${subject}, session: $session_label" | tee -a "$LOGFILE"
            fi

			# Report that process is finished and log with date and time
            echo "$(date +'%Y-%m-%d %H:%M:%S') - Post-processing completed: ${subject}, session: $session_label" | tee -a "$LOGFILE"
            echo "" | tee -a "$LOGFILE"	
        fi
    else
        echo "$folder is not a directory" | tee -a "$LOGFILE"
        echo "" | tee -a "$LOGFILE"	
    fi
done