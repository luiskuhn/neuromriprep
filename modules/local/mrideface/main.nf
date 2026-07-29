process MRI_DEFACE {

    tag "${meta.subject}_${meta.session}_${nifti.name}"

    container {
        task.ext.container ?: '/nic/sw/IRTG/sif/mri_deface.sif'
    }

    cpus   { (params.mri_deface_cpus ?: 8) as Integer }
    memory { params.mri_deface_mem ?: '8 GB' }
    time   { params.mri_deface_time ?: '2h' }

    input:
    tuple val(meta), path(bids_dir), path(nifti)

    output:
    tuple val(meta),
        path("sub-${meta.subject}/ses-${meta.session}/anat/*_defaced.nii.gz"),
        emit: defaced

    path("sub-${meta.subject}/ses-${meta.session}/anat/*_defaced.nii.gz"),
        emit: defaced_publish

    path("logs/*.log"),
        emit: logs

    path("versions.yml"),
        emit: version

    shell:
    '''
    set -euo pipefail

    export OMP_NUM_THREADS="!{task.cpus}"
    export OMP_THREADS="!{task.cpus}"

    sub="sub-!{meta.subject}"
    ses="ses-!{meta.session}"

    mkdir -p "$sub/$ses/anat" logs

    fname="$(basename "!{nifti}")"
    base="${fname%.nii.gz}"

    if [[ "$base" == "$fname" ]]; then
        base="${fname%.nii}"
    fi

    out_file="$sub/$ses/anat/${base}_defaced.nii.gz"

    log_prefix="sub-!{meta.subject}_ses-!{meta.session}_${base}"
    out_log="logs/${log_prefix}_out.log"
    err_log="logs/${log_prefix}_err.log"

    mri_deface_bin="!{params.mri_deface_bin ?: 'mri_deface'}"
    brain_tmpl="!{params.mri_deface_brain_template ?: '/opt/mri_deface/talairach_mixed_with_skull.gca'}"
    face_tmpl="!{params.mri_deface_face_template ?: '/opt/mri_deface/face.gca'}"

    # Resolve the actual executable path.
    if [[ "$mri_deface_bin" == */* ]]; then
        mri_deface_path="$mri_deface_bin"
    else
        mri_deface_path="$(
            command -v "$mri_deface_bin" 2>/dev/null || true
        )"
    fi

    # Attempt to determine the installed mri_deface version.
    get_mri_deface_version() {
        local version_output=""
        local detected_version=""

        if [[ -z "$mri_deface_path" ]] ||
           [[ ! -x "$mri_deface_path" ]]; then
            printf '%s' "unknown"
            return 0
        fi

        # Try common command-line version arguments.
        version_output="$(
            "$mri_deface_path" --version 2>&1 || true
        )"

        detected_version="$(
            printf '%s\n' "$version_output" |
            grep -Eio \
                'mri[_ -]?deface([^0-9]{0,30})?[0-9]+([.][0-9]+)+' |
            grep -Eo '[0-9]+([.][0-9]+)+' |
            head -n 1 ||
            true
        )"

        if [[ -z "$detected_version" ]]; then
            version_output="$(
                "$mri_deface_path" -version 2>&1 || true
            )"

            detected_version="$(
                printf '%s\n' "$version_output" |
                grep -Eio \
                    'mri[_ -]?deface([^0-9]{0,30})?[0-9]+([.][0-9]+)+' |
                grep -Eo '[0-9]+([.][0-9]+)+' |
                head -n 1 ||
                true
            )"
        fi

        # Some standalone builds only contain the version as embedded text.
        if [[ -z "$detected_version" ]] &&
           command -v strings >/dev/null 2>&1; then

            detected_version="$(
                strings "$mri_deface_path" 2>/dev/null |
                grep -Ei 'mri[_ -]?deface' |
                grep -Eo '[0-9]+([.][0-9]+)+' |
                head -n 1 ||
                true
            )"
        fi

        if [[ -n "$detected_version" ]]; then
            printf '%s' "$detected_version"
        else
            printf '%s' "unknown"
        fi
    }

    mri_deface_version="$(get_mri_deface_version)"

    # Always create the version file, including when the image is skipped.
    cat > versions.yml <<EOF
"!{task.process}":
  mri_deface: "$mri_deface_version"
EOF

    {
        echo "=== MRI_DEFACE ==="
        echo "BIDS_DIR:      !{bids_dir}"
        echo "INPUT:         !{nifti}"
        echo "OUTPUT:        $out_file"
        echo "BINARY:        $mri_deface_bin"
        echo "BINARY_PATH:   ${mri_deface_path:-unknown}"
        echo "VERSION:       $mri_deface_version"
        echo "BRAIN_TMPL:    $brain_tmpl"
        echo "FACE_TMPL:     $face_tmpl"
        echo "CPUS:          !{task.cpus}"
        echo "OMP_THREADS:   $OMP_THREADS"
        echo "DATE:          $(date -Is)"
        echo "=================="
        echo
    } | tee -a "$out_log"

    # Skip if the input filename already indicates that it was defaced.
    if [[ "$base" == *"_defaced" ]] ||
       [[ "$base" == *"_deface" ]]; then

        echo "[SKIP] Input already looks defaced: $base" |
            tee -a "$out_log"

        cp "!{nifti}" "$out_file"

        : >> "$err_log"

        exit 0
    fi

    # Verify that the executable is available.
    if [[ "$mri_deface_bin" != "mri_deface" ]]; then

        if [[ ! -x "$mri_deface_bin" ]]; then
            echo \
                "ERROR: mri_deface binary not executable: $mri_deface_bin" |
                tee -a "$err_log" >&2

            exit 127
        fi

    else

        if ! command -v mri_deface >/dev/null 2>&1; then
            echo \
                "ERROR: mri_deface not found in PATH" |
                tee -a "$err_log" >&2

            exit 127
        fi
    fi

    # Verify that both required template files are present.
    if [[ ! -f "$brain_tmpl" ]]; then
        echo \
            "ERROR: Missing brain template: $brain_tmpl" |
            tee -a "$err_log" >&2

        exit 1
    fi

    if [[ ! -f "$face_tmpl" ]]; then
        echo \
            "ERROR: Missing face template: $face_tmpl" |
            tee -a "$err_log" >&2

        exit 1
    fi

    "$mri_deface_bin" \
        "!{nifti}" \
        "$brain_tmpl" \
        "$face_tmpl" \
        "$out_file" \
        1> >(tee -a "$out_log") \
        2> >(tee \
            >(grep -i -e "warning" -e "error" >> "$err_log") \
            >&2
        )

    if [[ ! -f "$out_file" ]]; then
        echo \
            "ERROR: Expected output not created: $out_file" |
            tee -a "$err_log" >&2

        exit 1
    fi

    : >> "$err_log"
    '''
}