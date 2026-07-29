/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { BIDSING            } from '../subworkflows/local/bidsing'
include { MERGE_BIDS_DATASET } from '../modules/local/mergebidsdataset'
include { BIDS_VALIDATOR     } from '../modules/local/bidsvalidator'
include { BIDS_QC_GATE       } from '../modules/local/bidsqcgate'
include { BIDSIGNORE         } from '../modules/local/bidsignore'

include { MRIQC_PARTICIPANTS } from '../subworkflows/local/mriqc_participants'
include { MRIQC_GROUP        } from '../modules/local/mriqcgroup'

include { FMRIPREP_PARTICIPANTS } from '../subworkflows/local/fmriprep_participants'

include { PYDEFACE           } from '../modules/local/pydeface'
include { MRI_DEFACE         } from '../modules/local/mrideface'
include { FSL_DEFACE         } from '../modules/local/fsldeface'
include { AFNI_REFACER       } from '../modules/local/afnirefacer'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/


// helper function to normalize sub ids
def normalizeSubId(subject) {
    def s = subject.toString().trim()
    return s.startsWith('sub-') ? s : "sub-${s}"
}

workflow NEUROMRIPREP {

    take:
    ch_samplesheet  // channel: [ val(meta), path(dicom_dir) ]
    ch_config       // channel: path(config_file)

    main:

    // Aggregate version records from every component
    def ch_versions = Channel.empty()

    // Default: enforce the gate unless explicitly disabled
    def enforce_bidsqc_gate = params.enforce_bidsqc_gate == null ? true : params.enforce_bidsqc_gate

    // Extract subject and session from DICOM folder basename
    // Expected format: IRTGXX_SYY: XX is subject and YY is session
    ch_input = ch_samplesheet
        .map { meta, dicom_dir ->

            def folder_name = dicom_dir.name
            def parts       = folder_name.split('_')

            // Extract subject
            def subject = parts.size() > 1 ? parts[1] : "unknown"

            // Extract session
            def sesStr    = parts.size() > 2 ? parts[2] : ""
            def ses_match = sesStr =~ /S(\d+)/
            def ses       = ses_match ? ses_match[0][1] : "01"
            def session   = ses.padLeft(2, '0')

            def new_meta = meta + [
                subject: subject,
                session: session,
                project: meta.project
            ]

            tuple(new_meta, dicom_dir)
        }

    ch_force = Channel.value(params.force_dcm2bids ?: false)

    BIDSING(
        ch_input,
        ch_config,
        ch_force
    )

    ch_bids_raw = BIDSING.out.bids_raw
    ch_versions = ch_versions.mix(BIDSING.out.versions)

    ch_modified_cfg = BIDSING.out.modified_config

    ch_sub_dirs = BIDSING.out.bids_sub
        .map { meta, subdir -> subdir }
        .collect()

    ch_dwi_adc_dirs = BIDSING.out.dwi_adc_sub
        .map { meta, ddir -> ddir }
        .collect()

    ch_logs = BIDSING.out.dcm2bids_log.collect()


    // merge bids dataset
    MERGE_BIDS_DATASET(
        ch_sub_dirs,
        ch_dwi_adc_dirs,
        ch_logs
    )

    ch_bids_dataset       = MERGE_BIDS_DATASET.out.bids_dataset
    ch_bids_dataset_items = MERGE_BIDS_DATASET.out.bids_dataset_items.flatten()

    ch_dataset_meta = ch_samplesheet
        .map { meta, ignored -> meta }
        .first()
        .map { meta -> meta + [ id: 'dataset' ] }

    // read in ignore files
    ch_ignore_add = Channel.value(file('assets/input_pipeline/bidsignore_list.txt', checkIfExists: true))
    ch_ignore_remove = Channel.value(file('assets/input_pipeline/bidsignore_remove.txt', checkIfExists: true))

    ch_bidsignore_in = ch_dataset_meta
        .combine(ch_bids_dataset)
        .map { meta, ds -> tuple(meta, ds) }

    BIDSIGNORE(
        ch_bidsignore_in,
        ch_ignore_add,
        ch_ignore_remove
    )

    ch_bidsignore_dataset = BIDSIGNORE.out.bids_dataset
    ch_bidsignore = BIDSIGNORE.out.bidsignore_file

    ch_bidsval_in = ch_bidsignore_dataset
        .join(ch_bidsignore)

    // bidsvalidator
    BIDS_VALIDATOR(ch_bidsval_in)

    ch_versions = ch_versions.mix(BIDS_VALIDATOR.out.versions)

    ch_bidsval_log = BIDS_VALIDATOR.out.log

    def gate_py   = file(params.bids_qc_script)
    def allowlist = file(params.bids_qc_allowlist)
    def helpers   = params.bids_qc_helpers ? file(params.bids_qc_helpers) : []

    ch_bidsval_gate = ch_bidsval_log.map { meta, log ->
        tuple(meta, log, gate_py, allowlist, helpers)
    }

    // channels so it does not break when flags false
    def ch_bidsqcgate          = Channel.empty()
    def ch_mriqc_part_publish  = Channel.empty()
    def ch_mriqc_group_publish = Channel.empty()
    def ch_fmriprep_publish    = Channel.empty()
    def ch_defaced             = Channel.empty()
    def ch_deface_publish      = Channel.empty()

    if( params.bidsval_mcheck ) {
        log.warn "[BIDSVAL] Machine check"
    }

    BIDS_QC_GATE(ch_bidsval_gate)


    ch_bidsqcgate = BIDS_QC_GATE.out.summary

    // Dataset-level pass/fail status (because validation happens after merge)
    ch_bidsqc_status = BIDS_QC_GATE.out.passed
        .map { meta, passed_file ->
            def ok = passed_file.text.trim().toBoolean()
            tuple(meta, ok)
        }

    // Always report gate result
    ch_bidsqc_status.view { meta, ok ->
        def who = meta.id ?: meta.subject ?: 'dataset'
        "[BIDS] QC gate ${ok ? 'PASSED' : 'FAILED'} for ${who}"
    }

    // Single dataset dir after ignore processing
    ch_bids_dataset_after_ignore = ch_bidsignore_dataset
        .map { meta, outdir -> outdir }
        .first()

    // Downstream dataset channel:
    // - gated by BIDS_QC_GATE if enforce_bidsqc_gate=true
    // - passes through unchanged if enforce_bidsqc_gate=false
    def ch_bids_dataset_for_downstream = ch_bids_dataset_after_ignore

    if( enforce_bidsqc_gate ) {
        log.warn "[BIDS] BIDS_QC_GATE result will be enforced for downstream execution."

        ch_bidsqc_status
            .filter { meta, ok -> !ok }
            .view { meta, ok ->
                "[BIDS] QC failed. Downstream steps will not run. Fix the issues and re-run with -resume, or use --enforce_bidsqc_gate false to ignore the gate."
            }

        ch_bids_dataset_for_downstream = ch_bids_dataset_after_ignore
            .combine(ch_bidsqc_status)
            .filter { ds, meta, ok -> ok }
            .map { ds, meta, ok -> ds }

    } else {
        log.warn "[BIDS] BIDS_QC_GATE result will be reported but ignored because --enforce_bidsqc_gate false."
    }

    if( params.stop_bidsval ) {

        log.warn "[BIDS] Stopping after BIDS validation because --stop_bidsval true."

    } else {

        // MRIQC is dataset-level, matching the original bash scripts.
        // It runs once on the merged BIDS dataset, optionally restricted by --participant-label.
        ch_mriqc_dataset_in = ch_dataset_meta
            .combine(ch_bids_dataset_for_downstream)
            .map { meta, ds -> tuple(meta, ds) }


        //
        // MRIQC (optional)
        //
        if( params.skip_mriqc ) {

            log.warn "[MRIQC] Skipping MRIQC and MRIQC_GROUP because --skip_mriqc true."

        } else {

            /*
            * MRIQC_PARTICIPANTS now runs once at dataset level.
            * It should output one complete MRIQC participant output directory,
            * not one mriqc_out_<subject> directory per samplesheet row.
            */
            MRIQC_PARTICIPANTS(
                ch_mriqc_dataset_in,
                params.mriqc_vpn_file
            )

            ch_versions = ch_versions.mix(MRIQC_PARTICIPANTS.out.versions)

            // Publish participant-level MRIQC outputs
            ch_mriqc_part_pub = MRIQC_PARTICIPANTS.out.mriqc_out_pub.flatten()

            ch_mriqc_part_publish = ch_mriqc_part_pub.map { p ->
                def rel = p.toString().replaceFirst(/^.*\/mriqc_participant_out\//, '')
                [ file: p, rel: rel ]
            }

            /*
            * MRIQC_GROUP receives:
            *   meta
            *   BIDS dataset
            *   the single participant MRIQC output directory
            *
            * No collect(), no set of per-subject dirs, no duplicate basenames.
            */
            MRIQC_GROUP(
                MRIQC_PARTICIPANTS.out.mriqc_group_in
            )

            ch_versions = ch_versions.mix(MRIQC_GROUP.out.versions)

            ch_mriqc_group_publish = MRIQC_GROUP.out.mriqc_group_publish.flatten()

            ch_mriqc_group_publish = ch_mriqc_group_publish.map { p ->
                def rel = p.toString().replaceFirst(/^.*\/mriqc_group_out\//, '')
                [ file: p, rel: rel ]
            }

            if( params.stop_mriqc ) {
                log.warn "[MRIQC] Stopping after MRIQC. After resolving the issues re-run with -resume and --stop_mriqc false to continue."
            }
        }

        //
        // FMRIPREP (optional, only if not explicitly stopped after MRIQC)
        //
        if( !params.stop_mriqc || params.skip_mriqc ) {

            if( params.skip_fmriprep ) {

                log.warn "[FMRIPREP] Skipping FMRIPREP because --skip_fmriprep true."

            } else {

                FMRIPREP_PARTICIPANTS(
                    ch_input,
                    ch_bids_dataset_for_downstream
                )

                ch_versions = ch_versions.mix(FMRIPREP_PARTICIPANTS.out.fmriprep_versions)

                ch_fmriprep_publish = FMRIPREP_PARTICIPANTS.out.fmriprep_publish

                if( params.stop_fmriprep ) {
                    log.warn "[FMRIPREP] Stopping after FMRIPREP. After resolving the issues re-run with -resume and --stop_fmriprep false to continue."
                }
            }
        }

        //
        // DEFACING (run if not explicitly stopped after FMRIPREP)
        //
        if( !params.stop_fmriprep || params.skip_fmriprep ) {

            // Dataset dir (single value, possibly gated)
            def ch_deface_ds = ch_bids_dataset_for_downstream

            // Per-subject/session meta
            def ch_deface_meta = ch_input
                .map { meta, ignored -> meta }
                .map { meta -> meta + [ id: "sub-${meta.subject}" ] }

            // VPN list
            if( params.pydeface_vpn_file ) {
                def vpn_set = file(params.pydeface_vpn_file)
                    .text
                    .readLines()
                    .collect { it.replace('\r','').trim() }
                    .findAll { it }
                    .collect { it.replaceFirst(/^sub-/, '') }
                    .toSet()

                ch_deface_meta = ch_deface_meta.filter { meta ->
                    vpn_set.contains(meta.subject.toString().replaceFirst(/^sub-/, ''))
                }
            }

            def ch_deface_in = ch_deface_meta
                .combine(ch_deface_ds)
                .flatMap { meta, ds ->
                    def anatDir = new File(ds.toString(), "sub-${meta.subject}/ses-${meta.session}/anat")
                    if( !anatDir.exists() ) return []

                    def niiFiles = anatDir
                        .listFiles()
                        ?.findAll { it.name.endsWith('.nii.gz') && !it.name.endsWith('_defaced.nii.gz') }
                        ?: []

                    niiFiles.collect { f -> tuple(meta, ds, f.toPath()) }
                }

            if( params.deface_tool == 'mri_deface' ) {

                MRI_DEFACE(ch_deface_in)
                //ch_versions = ch_versions.mix(MRI_DEFACE.out.version)
                ch_defaced = MRI_DEFACE.out.defaced

                ch_deface_publish = MRI_DEFACE.out.defaced_publish
                    .flatten()
                    .map { p ->
                        def s = p.toString()
                        def parts = s.split(/[\\\/]+/)
                        def i = parts.findIndexOf { it.startsWith('sub-') }
                        if( i < 0 ) error "Could not derive rel path from: ${s}"
                        def rel = parts[i..-1].join('/')
                        [ file: p, rel: rel ]
                    }

            } else if( params.deface_tool == 'pydeface' ) {

                PYDEFACE(ch_deface_in)
                ch_versions = ch_versions.mix(PYDEFACE.out.version)
                ch_defaced = PYDEFACE.out.defaced

                ch_deface_publish = PYDEFACE.out.defaced_publish
                    .flatten()
                    .map { p ->
                        def s = p.toString()
                        def parts = s.split(/[\\\/]+/)
                        def i = parts.findIndexOf { it.startsWith('sub-') }
                        if( i < 0 ) error "Could not derive rel path from: ${s}"
                        def rel = parts[i..-1].join('/')
                        [ file: p, rel: rel ]
                    }

            } else if( params.deface_tool == 'fsl_deface' ) {

                FSL_DEFACE(ch_deface_in)
                //ch_versions = ch_versions.mix(FSL_DEFACE.out.version)
                ch_defaced = FSL_DEFACE.out.defaced

                ch_deface_publish = FSL_DEFACE.out.defaced_publish
                    .flatten()
                    .map { p ->
                        def s = p.toString()
                        def parts = s.split(/[\\\/]+/)
                        def i = parts.findIndexOf { it.startsWith('sub-') }
                        if( i < 0 ) error "Could not derive rel path from: ${s}"
                        def rel = parts[i..-1].join('/')
                        [ file: p, rel: rel ]
                    }

            } else if( params.deface_tool == 'afni_refacer' ) {

                AFNI_REFACER(ch_deface_in)
                //ch_versions = ch_versions.mix(AFNI_REFACER.out.version)
                ch_defaced = AFNI_REFACER.out.defaced

                ch_deface_publish = AFNI_REFACER.out.defaced_publish
                    .flatten()
                    .map { p ->
                        def s = p.toString()
                        def parts = s.split(/[\\\/]+/)
                        def i = parts.findIndexOf { it.startsWith('sub-') }
                        if( i < 0 ) error "Could not derive rel path from: ${s}"
                        def rel = parts[i..-1].join('/')
                        [ file: p, rel: rel ]
                    }

            }  else {
                error "Unsupported params.deface_tool: ${params.deface_tool}"
            }
        }
    }

    emit:
    dcm2bids_merge      = ch_bids_dataset_items
    modified_config     = ch_modified_cfg
    bidsgate_report     = ch_bidsqcgate
    bidsval_report      = ch_bidsval_log
    bidsignore_file     = ch_bidsignore
    mriqc_part_publish  = ch_mriqc_part_publish
    mriqc_group_publish = ch_mriqc_group_publish
    fmriprep_publish    = ch_fmriprep_publish
    deface_publish      = ch_deface_publish
    versions            = ch_versions
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/