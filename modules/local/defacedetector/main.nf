process DEFACE_DETECTOR {
    tag "${meta.id}"
    label 'process_single'

    container "${task.ext.container ?: '/nic/sw/IRTG/sif/deface_detector.sif'}"

    input:
    tuple val(meta), path(nii)
    path detector_script
    path model_dir

    output:
    tuple val(meta), path("*.deface_qc.json"), emit: qc_json
    tuple val(meta), path("*.deface_qc_pass.txt"), emit: qc_pass

    script:
    def prefix = nii.name.replaceFirst(/\.nii(\.gz)?$/, '')

    """
    set -euo pipefail

    node "${detector_script}" \
      --in "${nii}" \
      --model-dir "${model_dir}" \
      --threshold 0.5 \
      --out-json "${prefix}.deface_qc.json" \
      --out-pass "${prefix}.deface_qc_pass.txt"
    """
}