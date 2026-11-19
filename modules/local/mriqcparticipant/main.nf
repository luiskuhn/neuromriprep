process MRIQC_PARTICIPANT {

    tag "${meta.id ?: meta.project ?: 'dataset'}"


    input:
    tuple val(meta), path(bids_dataset), val(participant_labels)

    output:
    tuple val(meta), path("mriqc_participant_out"), emit: mriqc_out
    path "mriqc_participant_out/**", emit: mriqc_publish
    path "logs/**", optional: true, emit: mriqc_log
    path "versions.yml", emit: versions

    script:
    def labels_arg = participant_labels && participant_labels.size() > 0
        ? "--participant-label ${participant_labels.join(' ')}"
        : ""

    """
    set -euo pipefail

    BIDS_DIR="\$(realpath "${bids_dataset}")"

    mkdir -p mriqc_participant_out
    mkdir -p mriqc_work
    mkdir -p logs/logs_subjects

    LOGFILE="logs/logs_subjects/mriqc_errlog_\$(date +"%Y-%m-%d-%H-%M")_\$\$.txt"

    echo "MRIQC Processing Log - \$(date)" | tee -a "\$LOGFILE"
    echo "Input directory: \$BIDS_DIR" | tee -a "\$LOGFILE"
    echo "Output directory: \$PWD/mriqc_participant_out" | tee -a "\$LOGFILE"
    echo "Working directory: \$PWD/mriqc_work" | tee -a "\$LOGFILE"

    mriqc \\
        "\$BIDS_DIR" \\
        "\$PWD/mriqc_participant_out" \\
        participant \\
        ${labels_arg} \\
        --nprocs "${task.cpus}" \\
        --omp-nthreads "${params.mriqc_omp_threads ?: 4}" \\
        --mem_gb "${task.memory.toGiga()}" \\
        --no-sub \\
        -v \\
        --verbose-reports \\
        --work-dir "\$PWD/mriqc_work" \\
        2> >(grep -Ev 'it/s]' | tee -a "\$LOGFILE" >&2)

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mriqc: "\$(mriqc --version 2>/dev/null | tail -n 1 | tr -d '\\n' || echo unknown)"
    END_VERSIONS
    """
}
