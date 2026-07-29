process DEEPDEFACER {

    tag "${meta.subject}_${meta.session}_${nifti.name}"

    container { task.ext.container ?: '/home/loboehme/Documents/container/ownconts/deepdefacer.sif' }

    cpus   { (params.deepdefacer_cpus ?: 8) as Integer }
    memory {  params.deepdefacer_mem  ?: '8 GB' }
    time   {  params.deepdefacer_time ?: '2h' }

    input:
    tuple val(meta), path(bids_dir), path(nifti)

    output:
    tuple val(meta), path("sub-${meta.subject}/ses-${meta.session}/anat/*_defaced.nii.gz"), emit: defaced
    path("sub-${meta.subject}/ses-${meta.session}/anat/*_defaced.nii.gz"), emit: defaced_publish
    path("logs/*.log"), emit: logs
    path("sub-${meta.subject}/ses-${meta.session}/anat/*_deepdefacer_mask.nii.gz"), emit: mask, optional: true

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
    mask_file="$sub/$ses/anat/${base}_deepdefacer_mask.nii.gz"

    log_prefix="sub-!{meta.subject}_ses-!{meta.session}_${base}"
    out_log="logs/${log_prefix}_out.log"
    err_log="logs/${log_prefix}_err.log"

    {
      echo "=== DEEPDEFACER ==="
      echo "BIDS_DIR:      !{bids_dir}"
      echo "INPUT:         !{nifti}"
      echo "OUTPUT:        $out_file"
      echo "MASK_OUTPUT:   $mask_file"
      echo "CPUS:          !{task.cpus}"
      echo "OMP_THREADS:   $OMP_THREADS"
      echo "DATE:          $(date -Is)"
      echo "=================="
      echo
    } | tee -a "$out_log"

    # Skip if input already looks defaced, but still create declared output
    if [[ "$base" == *"_defaced" ]] || [[ "$base" == *"_deface" ]]; then
      echo "[SKIP] Input already looks defaced: $base" | tee -a "$out_log"
      cp "!{nifti}" "$out_file"
      : >> "$err_log"
      exit 0
    fi

    if ! command -v deepdefacer >/dev/null 2>&1; then
      echo "ERROR: deepdefacer not found in container PATH" | tee -a "$err_log" >&2
      exit 127
    fi

    if [[ "!{params.deepdefacer_save_mask ?: false}" == "true" ]]; then
      deepdefacer \
        --input_file "!{nifti}" \
        --defaced_output_path "$out_file" \
        --mask_output_path "$mask_file" \
        1> >(tee -a "$out_log") \
        2> >(tee >(grep -i -e "warning" -e "error" >> "$err_log") >&2)
    else
      deepdefacer \
        --input_file "!{nifti}" \
        --defaced_output_path "$out_file" \
        1> >(tee -a "$out_log") \
        2> >(tee >(grep -i -e "warning" -e "error" >> "$err_log") >&2)
    fi

    [[ -f "$out_file" ]] || { echo "ERROR: Expected output not created: $out_file" | tee -a "$err_log" >&2; exit 1; }

    : >> "$err_log"
    '''
}
