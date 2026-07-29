process BIDS_VALIDATOR {

    tag "${meta.id}"
    label 'process_low'

    container "${ task.ext.container ?: '/nic/sw/IRTG/sif/bidsvalidator_bash.sif' }"

    input:
    tuple val(meta), path(input_dir), path(bidsignore_file, stageAs: 'incoming_bidsignore.txt')

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}_validation_log.txt")    , emit: log
    tuple val(meta), path("${task.ext.prefix ?: meta.id}_validation_summary.txt"), emit: summary
    path "versions.yml"                                                          , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"

    """
    set -euo pipefail

    status=0
    TARGET_BIDSIGNORE="${input_dir}/.bidsignore"

    : > ${prefix}_validation_log.txt

    # Ensure .bidsignore exists where bids-validator expects it.
    if [ -f "${bidsignore_file}" ]; then
        if [ ! -f "\${TARGET_BIDSIGNORE}" ] || ! cmp -s "${bidsignore_file}" "\${TARGET_BIDSIGNORE}"; then
            cp -f "${bidsignore_file}" "\${TARGET_BIDSIGNORE}"
        fi
    fi

    # Run validator. Capture exit code, but do not fail the pipeline.
    bids-validator \\
        "${input_dir}" \\
        --verbose \\
        ${args} \\
        >> ${prefix}_validation_log.txt 2>&1 || status=\$?

    errors=\$(grep -cE '^\\s*\\[ERROR\\]' ${prefix}_validation_log.txt 2>/dev/null || true)
    warns=\$(grep -cE '^\\s*\\[(WARNING|WARN)\\]' ${prefix}_validation_log.txt 2>/dev/null || true)

    log_path="\$(pwd)/${prefix}_validation_log.txt"

    cat > ${prefix}_validation_summary.txt <<EOF
    dataset_dir=${input_dir}
    log_path=\${log_path}
    exit_code=\${status}
    errors=\${errors}
    warnings=\${warns}
    EOF

    bids_validator_version=\$(
        bids-validator --version 2>&1 |
        sed "s/\$(printf '\\033')\\[[0-9;]*m//g" |
        awk '{ print \$NF }'
    )

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
    bids-validator: "\${bids_validator_version}"
    END_VERSIONS

    exit 0
    """
}