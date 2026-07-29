process PYDEFACE {

    tag "${meta.subject}_${meta.session}_${nifti.name}"

    container {
        task.ext.container ?: '/nic/sw/IRTG/sif/pydeface_3.0.sif'
    }

    cpus   { (params.pydeface_cpus ?: 8) as Integer }
    memory { params.pydeface_mem ?: '8 GB' }
    time   { params.pydeface_time ?: '2h' }

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

    base="$(basename "!{nifti}" .nii.gz)"
    out_file="$sub/$ses/anat/${base}_defaced.nii.gz"

    log_prefix="sub-!{meta.subject}_ses-!{meta.session}_${base}"
    out_log="logs/${log_prefix}_out.log"
    err_log="logs/${log_prefix}_err.log"

    # Extract the installed pydeface package version.
    get_pydeface_version() {
        if command -v python3 >/dev/null 2>&1; then
            python3 -c \
                'from importlib.metadata import version; print(version("pydeface"))' \
                2>/dev/null && return 0
        fi

        if command -v python >/dev/null 2>&1; then
            python -c \
                'from importlib.metadata import version; print(version("pydeface"))' \
                2>/dev/null && return 0
        fi

        printf '%s' "unknown"
    }

    pydeface_version="$(get_pydeface_version)"
    pydeface_version="$(printf '%s' "$pydeface_version" | tail -n 1 | xargs)"

    if [[ -z "$pydeface_version" ]]; then
        pydeface_version="unknown"
    fi

    cat > versions.yml <<EOF
"!{task.process}":
  pydeface: "$pydeface_version"
EOF

    {
        echo "=== PYDEFACE ==="
        echo "BIDS_DIR:      !{bids_dir}"
        echo "INPUT:         !{nifti}"
        echo "OUTPUT:        $out_file"
        echo "VERSION:       $pydeface_version"
        echo "CPUS:          !{task.cpus}"
        echo "OMP_THREADS:   $OMP_THREADS"
        echo "DATE:          $(date -Is)"
        echo "==============="
        echo
    } | tee -a "$out_log"

    # Skip input files whose names already end in _defaced.
    if [[ "$base" == *"_defaced" ]]; then
        echo "[SKIP] Input already looks defaced: $base" |
            tee -a "$out_log"

        cp "!{nifti}" "$out_file"
        : >> "$err_log"
        exit 0
    fi

    if command -v pydeface >/dev/null 2>&1; then
        pydeface "!{nifti}" \
            --outfile "$out_file" \
            1> >(tee -a "$out_log") \
            2> >(tee \
                >(grep -i -e "warning" -e "error" >> "$err_log") \
                >&2
            )

    elif command -v python3 >/dev/null 2>&1; then
        python3 -m pydeface "!{nifti}" \
            --outfile "$out_file" \
            1> >(tee -a "$out_log") \
            2> >(tee \
                >(grep -i -e "warning" -e "error" >> "$err_log") \
                >&2
            )

    else
        echo \
            "ERROR: Neither pydeface nor python3 is available in the container." \
            >&2
        exit 127
    fi

    : >> "$err_log"
    '''
}