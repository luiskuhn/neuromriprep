process DCM2BIDS_POSTPROC {

    label 'process_single'

    container "${ task.ext.container ?: '/nic/sw/IRTG/sif/docker-curl-jq.sif' }"

    input:
    tuple val(meta), path(bids_dir)

    output:
    tuple val(meta), path("sub-${meta.subject}"), emit: bids_sub
    tuple val(meta), path("derivatives/dwi_ADC/sub-${meta.subject}"), emit: dwi_adc_sub

    script:
    def subject  = meta.subject
    def session  = meta.session
    def bidsName = bids_dir.getName()   // staged dir name, e.g. "ses-01"

    """
    set -euo pipefail

    # final folder structure

    final_bids_dir="sub-${subject}/ses-${session}"
    orig_bids_dir="${bidsName}"

    mkdir -p "sub-${subject}"

    if [ -d "\${orig_bids_dir}" ] && [ "\${orig_bids_dir}" != "\${final_bids_dir}" ]; then
        mv "\${orig_bids_dir}" "\${final_bids_dir}"
    fi

    # In case input already arrived as sub-<subject>/ses-<session>
    if [ -d "sub-${subject}/ses-${session}" ] && [ ! -d "\${final_bids_dir}" ]; then
        mkdir -p "sub-${subject}"
        mv "sub-${subject}/ses-${session}" "\${final_bids_dir}"
    fi

    # Remove Acquisitionduration from all *_bold.json

    bold_jsons=\$(find "\${final_bids_dir}" -type f -name "*_bold.json" 2>/dev/null || true)

    if [ -n "\${bold_jsons}" ]; then
        for json_file in \${bold_jsons}; do
            if [ -f "\${json_file}" ]; then
                if jq "del(.Acquisitionduration)" "\${json_file}" > "\${json_file}.tmp" && mv "\${json_file}.tmp" "\${json_file}"; then
                    :
                else
                    echo "Warning: failed to update \${json_file}" >&2
                fi
            fi
        done
    fi


    # 2) Handle ADC derivatives -> derivatives/dwi_ADC/sub-<subject>/ses-<session>

    derivatives_dwi_adc="derivatives/dwi_ADC/sub-${subject}/ses-${session}"
    mkdir -p "\${derivatives_dwi_adc}"

    search_dirs=""
    for d in anat dwi fmap func; do
        if [ -d "\${final_bids_dir}/\${d}" ]; then
            search_dirs="\${search_dirs} \${final_bids_dir}/\${d}"
        fi
    done

    adc_files=\$(
        for r in \${search_dirs}; do
            if [ -d "\${r}" ]; then
                find "\${r}" -type f -iname "*adc*" -print 2>/dev/null || true
            fi
        done
    )

    if [ -n "\${adc_files}" ]; then
        while IFS= read -r f; do
            [ -f "\${f}" ] || continue
            mv "\${f}" "\${derivatives_dwi_adc}/"
        done << EOF
\${adc_files}
EOF
    fi


    # Remove sbref.bval / sbref.bvec (only in dwi/)

    if [ -d "\${final_bids_dir}/dwi" ]; then
        sbref_files=\$(find "\${final_bids_dir}/dwi" -type f \\( -name "*sbref.bval" -o -name "*sbref.bvec" \\) -print 2>/dev/null || true)
        if [ -n "\${sbref_files}" ]; then
            rm -f \${sbref_files} 2>/dev/null || true
        fi
    fi


    # Remove tmp_dcm2bids if present

    rm -rf tmp_dcm2bids || true
    """

    stub:
    """
    set -euo pipefail
    mkdir -p "sub-${meta.subject}/ses-${meta.session}"
    mkdir -p "derivatives/dwi_ADC/sub-${meta.subject}/ses-${meta.session}"
    """
}
