process DCM2BIDS_OUTPUT_PATCH {

    tag "${meta.subject}"
    label 'process_low'

    container "${ task.ext.container ?: '/nic/sw/IRTG/sif/dcm2bids_3.2.0.sif' }"

    input:
    tuple val(meta), path(bids_session_in, stageAs: 'bids_input')
    path(vpn_file, stageAs: 'vpn_subjects.txt')

    output:
    tuple val(meta), path("sub-${meta.subject}/ses-${meta.session}"), emit: bids_output
    path("b0field_output_patch_report.json"), emit: report

    script:
    def subject = meta.subject.toString().replaceFirst(/^sub-/, '')
    def session = meta.session.toString().replaceFirst(/^ses-/, '').padLeft(2, '0')

    """
    set -euo pipefail

    mkdir -p sub-${subject}/ses-${session}
    cp -a bids_input/. sub-${subject}/ses-${session}/

    dcm2bids_output_patch.py \
        --bids-dir . \
        --vpn-file vpn_subjects.txt \
        --subject '${subject}' \
        --session '${session}' \
        --out-report b0field_output_patch_report.json

    python3 -m json.tool b0field_output_patch_report.json >/dev/null
    """
}