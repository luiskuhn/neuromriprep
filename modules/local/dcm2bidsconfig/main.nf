
process DCM2BIDS_CONFIG{

    label 'process_single'

    // ubuntu jq container
    container "${ task.ext.container ?: '/nic/sw/IRTG/sif/docker-curl-jq.sif' }"

    input:
    tuple val(meta), path(config_file)

    output:
    // Emit meta again so we can join later
    tuple val(meta), path("modified_config.json"), emit: config

    when:
    task.ext.when == null || task.ext.when

    script:
    """
    echo "Creating modified config for project ${meta.project}"
    echo "subject ${meta.subject}, session ${meta.session}"
    ls -la

    export DEFAULT_FMAP_SUFFIX="_ses-${meta.session}"
    export PEPOLAR_FMAP_SUFFIX="_ses${meta.session}" # causes fmriprep to fail if with '-'

    jq '
      def has_session_suffix:
        test("_ses[-_]?[0-9]+\$");

      def add_fmap_session_suffix:
        if type == "string"
           and test("_fmap")
           and (has_session_suffix | not)
        then
          . + (
            if startswith("pepolar")
            then env.PEPOLAR_FMAP_SUFFIX
            else env.DEFAULT_FMAP_SUFFIX
            end
          )
        else
          .
        end;

      .descriptions |= map(
        if .sidecar_changes?.B0FieldIdentifier? != null
           and (.sidecar_changes.B0FieldIdentifier | type == "string")
        then
          .sidecar_changes.B0FieldIdentifier |= add_fmap_session_suffix
        else
          .
        end
        |
        if .sidecar_changes?.B0FieldSource? != null
        then
          if (.sidecar_changes.B0FieldSource | type == "string")
          then
            .sidecar_changes.B0FieldSource |= add_fmap_session_suffix
          elif (.sidecar_changes.B0FieldSource | type == "array")
               and (.sidecar_changes.B0FieldSource | all(. | type == "string"))
          then
            .sidecar_changes.B0FieldSource |= map(add_fmap_session_suffix)
          else
            .
          end
        else
          .
        end
      )
    ' ${config_file} > modified_config.json

    if [ ! -s modified_config.json ]; then
        echo "Error: Failed to create modified config file"
        exit 1
    fi

    echo "Modified config created for ses-${meta.session}"
    """
}
