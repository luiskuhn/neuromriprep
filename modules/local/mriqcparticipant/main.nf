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

    apptainer run \\
        -B "\$PWD/mriqc_work:/work_dir" \\
        -B "\$BIDS_DIR:/input_dir:ro" \\
        -B "\$PWD/mriqc_participant_out:/output_dir" \\
        "${params.mriqc_container ?: '/nic/sw/IRTG/sif/mriqc_25.0.0rc0.sif'}" \\
        "/input_dir" \\
        "/output_dir" \\
        participant \\
        ${labels_arg} \\
        --nprocs "${task.cpus}" \\
        --omp-nthreads "${params.mriqc_omp_threads ?: 4}" \\
        --mem_gb "${task.memory.toGiga()}" \\
        --no-sub \\
        -v \\
        --verbose-reports \\
        --work-dir "/work_dir" \\
        2> >(grep -Ev 'it/s]' | tee -a "\$LOGFILE" >&2)

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mriqc: 25.0.0rc0
    END_VERSIONS
    """
}