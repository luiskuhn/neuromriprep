process AFNI_REFACER {

    tag "${meta.subject}_${meta.session}_${nifti.name}"

    container { task.ext.container ?: '/nic/sw/IRTG/sif/afni_refacer_pennlinc.sif' }

    cpus   { (params.afni_refacer_cpus ?: 8) as Integer }
    memory {  params.afni_refacer_mem  ?: '8 GB' }
    time   {  params.afni_refacer_time ?: '2h' }

    input:
    tuple val(meta), path(bids_dir), path(nifti)

    output:
    tuple val(meta), path("sub-${meta.subject}/ses-${meta.session}/anat/*_defaced.nii.gz"), emit: defaced
    path("sub-${meta.subject}/ses-${meta.session}/anat/*_defaced.nii.gz"), emit: defaced_publish
    path("logs/*.log"), emit: logs
    path("sub-${meta.subject}/ses-${meta.session}/anat/*_face.nii.gz"), emit: replacement_face, optional: true
    path("sub-${meta.subject}/ses-${meta.session}/anat/*_QC"), emit: qc_dir, optional: true

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
    prefix_noext="$sub/$ses/anat/${base}_defaced"

    log_prefix="sub-!{meta.subject}_ses-!{meta.session}_${base}"
    out_log="logs/${log_prefix}_out.log"
    err_log="logs/${log_prefix}_err.log"

    afni_refacer_bin="!{params.afni_refacer_bin ?: '@afni_refacer_run'}"
    afni_shell_opt="!{params.afni_refacer_shell ?: ''}"
    anonymize_opt="!{params.afni_refacer_anonymize ?: false}"
    no_images_opt="!{params.afni_refacer_no_images ?: true}"

    # Skip if input already looks defaced, but still create declared output
    if [[ "$base" == *"_defaced" ]] || [[ "$base" == *"_deface" ]]; then
      echo "[SKIP] Input already looks defaced: $base" | tee -a "$out_log"
      cp "!{nifti}" "$out_file"
      : >> "$err_log"
      exit 0
    fi

    if [[ "$afni_refacer_bin" != "@afni_refacer_run" ]]; then
      [[ -x "$afni_refacer_bin" ]] || { echo "ERROR: AFNI refacer binary not executable: $afni_refacer_bin" | tee -a "$err_log" >&2; exit 127; }
    else
      command -v @afni_refacer_run >/dev/null 2>&1 || { echo "ERROR: @afni_refacer_run not found in PATH" | tee -a "$err_log" >&2; exit 127; }
    fi

    cmd=( "$afni_refacer_bin"
          -input "!{nifti}"
          -mode_deface
          -prefix "$out_file"
          -overwrite 
        )

    if [[ "$no_images_opt" == "true" ]]; then
      cmd+=( -no_images )
    fi

    if [[ "$anonymize_opt" == "true" ]]; then
      cmd+=( -anonymize_output )
    fi

    if [[ -n "$afni_shell_opt" ]]; then
      cmd+=( -shell "$afni_shell_opt" )
    fi

    "${cmd[@]}" \
      1> >(tee -a "$out_log") \
      2> >(tee >(grep -i -e "warning" -e "error" >> "$err_log") >&2)

    [[ -f "$out_file" ]] || { echo "ERROR: Expected output not created: $out_file" | tee -a "$err_log" >&2; exit 1; }

    : >> "$err_log"
    '''
}
