process MRIQC_GROUP {

    tag "${meta.id ?: meta.project ?: 'dataset'}"


    input:
    tuple val(meta), path(bids_dataset), path(mriqc_participant_out)

    output:
    path "mriqc_group_out/**", emit: mriqc_group_publish
    path "logs/**", optional: true, emit: mriqc_log
    path "versions.yml", emit: versions

    script:
    """
    set -euo pipefail

    BIDS_DIR="\$(realpath "${bids_dataset}")"

    mkdir -p mriqc_group_out
    mkdir -p mriqc_group_work
    mkdir -p logs/logs_group

    # MRIQC group expects the participant outputs already in /output_dir.
    cp -a "${mriqc_participant_out}/." mriqc_group_out/

    LOGFILE="logs/logs_group/mriqc_errlog_\$(date +'%Y-%m-%d-%H-%M').txt"

    echo "MRIQC Processing Log Group - \$(date)" > "\$LOGFILE"
    echo "Input directory: \$BIDS_DIR" | tee -a "\$LOGFILE"
    echo "Output directory: \$PWD/mriqc_group_out" | tee -a "\$LOGFILE"
    echo "Working directory: \$PWD/mriqc_group_work" | tee -a "\$LOGFILE"

    mriqc \\
        "\$BIDS_DIR" \\
        "\$PWD/mriqc_group_out" \\
        group \\
        --mem_gb "${task.memory.toGiga()}" \\
        --no-sub \\
        --work-dir "\$PWD/mriqc_group_work" \\
        2>&1 | tee -a "\$LOGFILE"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mriqc: "\$(mriqc --version 2>/dev/null | tail -n 1 | tr -d '\\n' || echo unknown)"
    END_VERSIONS
    """
}
