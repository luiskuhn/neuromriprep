

process DCM2BIDS {

    label 'process_single'



    container "${ task.ext.container ?: '/nic/sw/IRTG/sif/dcm2bids_3.2.0.sif' }"

    input:
    // meta + dicom + modified config + force flag
    tuple val(meta), path(dicom_dir), path(modified_config)
    val  force_reprocessing

    output:
    tuple val(meta), path("sub-${meta.subject}/ses-${meta.session}") , emit: bids_output
    path "logs_dcm2bids/*.log"                                       , emit: log
    path "versions.yml"                                              , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args       = task.ext.args ?: ''
    def force_flag = force_reprocessing ? '--force_dcm2bids' : ''
    def prefix     = "sub-${meta.subject}_ses-${meta.session}"

    """
    echo "Running dcm2bids for project ${meta.project}"
    echo "subject ${meta.subject}, session ${meta.session}"
    ls -la


    mkdir -p logs_dcm2bids

    dcm2bids \\
        -p ${meta.subject} \\
        -s ses-${meta.session} \\
        -c ${modified_config} \\
        -d ${dicom_dir} \\
        -o . \\
        ${force_flag} ${args} 2>&1 | tee logs_dcm2bids/${prefix}_dcm2bids.log

    dcm2bids_version=\$(python - <<'PY'
    from dcm2bids.version import __version__
    print(__version__)
    PY
    )

    if command -v jq >/dev/null 2>&1; then
        jq_version=\$(jq --version | sed 's/^jq-//')
    else
        jq_version="not-installed"
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
    dcm2bids: "\${dcm2bids_version}"
    jq: "\${jq_version}"
    END_VERSIONS
    """
}
