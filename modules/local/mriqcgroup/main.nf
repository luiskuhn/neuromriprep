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

    apptainer run \\
        -B "\$PWD/mriqc_group_work:/work_dir" \\
        -B "\$BIDS_DIR:/input_dir:ro" \\
        -B "\$PWD/mriqc_group_out:/output_dir" \\
        "/nic/sw/IRTG/sif/mriqc_25.0.0rc0.sif" \\
        "/input_dir" \\
        "/output_dir" \\
        group \\
        --mem_gb "${task.memory.toGiga()}" \\
        --no-sub \\
        --work-dir "/work_dir" \\
        2>&1 | tee -a "\$LOGFILE"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mriqc: 25.0.0rc0
    END_VERSIONS
    """
}