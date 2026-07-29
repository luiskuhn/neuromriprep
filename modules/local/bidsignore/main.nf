process BIDSIGNORE {

    tag "${meta.id}"
    label 'process_low'
    stageInMode 'copy'

    container "${ task.ext.container ?: '/nic/sw/IRTG/sif/docker-curl-jq.sif' }"

    input:
    tuple val(meta), path(dataset_dir, stageAs: 'bids_dataset')
    path(ignore_add)
    path(ignore_remove)

    output:
    tuple val(meta), path("bids_dataset"), emit: bids_dataset
    tuple val(meta), path("bids_dataset/.bidsignore", hidden: true), emit: bidsignore_file
    path("*.log"), emit: log
    path("versions.yml"), emit: versions

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"

    """
    set -euo pipefail

    INPUT_DIR="bids_dataset"
    BIDSIGNORE_FILE="\$INPUT_DIR/.bidsignore"
    LOGFILE="${prefix}_bidsignore.log"

    echo "\$(date +"%Y-%m-%d %H:%M:%S") - Dataset root: \$(pwd)/\$INPUT_DIR" | tee -a "\$LOGFILE"

    # Ensure .bidsignore exists
    if [ ! -f "\$BIDSIGNORE_FILE" ]; then
      echo "\$(date +"%Y-%m-%d %H:%M:%S") - Creating .bidsignore" | tee -a "\$LOGFILE"
      : > "\$BIDSIGNORE_FILE"
    fi

    echo "\$(date +"%Y-%m-%d %H:%M:%S") - Initial .bidsignore:" | tee -a "\$LOGFILE"
    sed -n '1,200p' "\$BIDSIGNORE_FILE" | tee -a "\$LOGFILE" || true
    echo | tee -a "\$LOGFILE"

    # Add entries
    while IFS= read -r ITEM || [ -n "\$ITEM" ]; do
      ITEM="\${ITEM%\$'\\r'}"
      [ -z "\$ITEM" ] && continue
      case "\$ITEM" in
        \\#*) continue ;;
      esac

      if ! grep -Fxq "\$ITEM" "\$BIDSIGNORE_FILE"; then
        echo "\$(date +"%Y-%m-%d %H:%M:%S") - Adding '\$ITEM'" | tee -a "\$LOGFILE"
        echo "\$ITEM" >> "\$BIDSIGNORE_FILE"
      fi
    done < "${ignore_add}"

    # Remove entries
    if [ -s "${ignore_remove}" ]; then
      while IFS= read -r ITEM || [ -n "\$ITEM" ]; do
        ITEM="\${ITEM%\$'\\r'}"
        [ -z "\$ITEM" ] && continue
        case "\$ITEM" in
          \\#*) continue ;;
        esac

        if grep -Fxq "\$ITEM" "\$BIDSIGNORE_FILE"; then
          echo "\$(date +"%Y-%m-%d %H:%M:%S") - Removing '\$ITEM'" | tee -a "\$LOGFILE"
          grep -Fxv "\$ITEM" "\$BIDSIGNORE_FILE" > "\${BIDSIGNORE_FILE}.tmp"
          mv "\${BIDSIGNORE_FILE}.tmp" "\$BIDSIGNORE_FILE"
        fi
      done < "${ignore_remove}"
    fi

    echo "\$(date +"%Y-%m-%d %H:%M:%S") - Final .bidsignore:" | tee -a "\$LOGFILE"
    sed -n '1,200p' "\$BIDSIGNORE_FILE" | tee -a "\$LOGFILE" || true
    echo | tee -a "\$LOGFILE"

    printf '"%s":\\n  tool: "shell"\\n' "${task.process}" > versions.yml
    """
}