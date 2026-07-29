#!/usr/bin/env nextflow

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS / WORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { NEUROMRIPREP     } from './workflows/neuromriprep'
include { DEFACE_BENCHMARK } from './workflows/deface_benchmark'
//include { PIPELINE_INITIALISATION } from './subworkflows/local/utils_nfcore_neuromriprep_pipeline'
//include { PIPELINE_COMPLETION     } from './subworkflows/local/utils_nfcore_neuromriprep_pipeline'
//include { samplesheetToList       } from 'plugin/nf-schema'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NAMED WORKFLOWS FOR PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// WORKFLOW: Run main analysis pipeline depending on type of input
//
workflow NFCORE_NEUROMRIPREP {

    main:

    ch_samplesheet = Channel
        .fromPath(params.input)
        .splitCsv(header: true)
        .map { row ->
            def meta = [
                id     : row.project,
                project: row.project
            ]
            [meta, file(row.dicom_dir)]
        }

    ch_config = Channel.fromPath(
        params.dcm2bids_config,
        checkIfExists: true
    )

    //
    // WORKFLOW: Run pipeline
    //
    NEUROMRIPREP(
        ch_samplesheet,
        ch_config
    )

    emit:
    dcm2bids_merge      = NEUROMRIPREP.out.dcm2bids_merge
    modified_config     = NEUROMRIPREP.out.modified_config
    bidsgate_report     = NEUROMRIPREP.out.bidsgate_report
    bidsval_report      = NEUROMRIPREP.out.bidsval_report
    bidsignore_file     = NEUROMRIPREP.out.bidsignore_file
    mriqc_part_publish  = NEUROMRIPREP.out.mriqc_part_publish
    mriqc_group_publish = NEUROMRIPREP.out.mriqc_group_publish
    fmriprep_publish    = NEUROMRIPREP.out.fmriprep_publish
    deface_publish      = NEUROMRIPREP.out.deface_publish
    versions            = NEUROMRIPREP.out.versions
}


workflow NFCORE_DEFACE_BENCHMARK {

    main:

    ch_samplesheet = Channel
        .fromPath(params.input)
        .splitCsv(header: true)
        .map { row ->
            def meta = [
                id     : row.project,
                project: row.project
            ]
            [meta, file(row.dicom_dir)]
        }

    ch_config = Channel.fromPath(
        params.dcm2bids_config,
        checkIfExists: true
    )

    DEFACE_BENCHMARK(
        ch_samplesheet,
        ch_config
    )

    emit:
    benchmark_defaced   = DEFACE_BENCHMARK.out.benchmark_defaced
    benchmark_qc        = DEFACE_BENCHMARK.out.benchmark_qc
    benchmark_metrics   = DEFACE_BENCHMARK.out.benchmark_metrics
    benchmark_summary   = DEFACE_BENCHMARK.out.benchmark_summary
    benchmark_defacedet = DEFACE_BENCHMARK.out.benchmark_defacedet
    versions            = DEFACE_BENCHMARK.out.versions
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

params.mode = params.mode ?: 'production'


workflow {

    main:

    // Initialize all possible outputs as empty channels.
    merge_out       = Channel.empty()
    config_out      = Channel.empty()
    bidsqc_out      = Channel.empty()
    bidsignore_out  = Channel.empty()
    bidsval_out     = Channel.empty()
    mriqc_part_out  = Channel.empty()
    mriqc_group_out = Channel.empty()
    fmriprep_out    = Channel.empty()
    deface_out      = Channel.empty()

    benchmark_metrics_out   = Channel.empty()
    benchmark_qc_out        = Channel.empty()
    benchmark_files_out     = Channel.empty()
    benchmark_summary_out   = Channel.empty()
    benchmark_defacedet_out = Channel.empty()

    // Raw per-process versions.yml fragments from the selected workflow.
    versions_source_out = Channel.empty()


    if( params.mode == 'production' ) {

        NFCORE_NEUROMRIPREP()

        merge_out       = NFCORE_NEUROMRIPREP.out.dcm2bids_merge
        config_out      = NFCORE_NEUROMRIPREP.out.modified_config
        bidsqc_out      = NFCORE_NEUROMRIPREP.out.bidsgate_report
        bidsval_out     = NFCORE_NEUROMRIPREP.out.bidsval_report
        bidsignore_out  = NFCORE_NEUROMRIPREP.out.bidsignore_file
        mriqc_part_out  = NFCORE_NEUROMRIPREP.out.mriqc_part_publish
        mriqc_group_out = NFCORE_NEUROMRIPREP.out.mriqc_group_publish
        fmriprep_out    = NFCORE_NEUROMRIPREP.out.fmriprep_publish
        deface_out      = NFCORE_NEUROMRIPREP.out.deface_publish

        versions_source_out = NFCORE_NEUROMRIPREP.out.versions

    } else if( params.mode == 'benchmark_defacing' ) {

        NFCORE_DEFACE_BENCHMARK()

        benchmark_metrics_out   = NFCORE_DEFACE_BENCHMARK.out.benchmark_metrics
        benchmark_qc_out        = NFCORE_DEFACE_BENCHMARK.out.benchmark_qc
        benchmark_files_out     = NFCORE_DEFACE_BENCHMARK.out.benchmark_defaced
        benchmark_summary_out   = NFCORE_DEFACE_BENCHMARK.out.benchmark_summary
        benchmark_defacedet_out = NFCORE_DEFACE_BENCHMARK.out.benchmark_defacedet

        versions_source_out = NFCORE_DEFACE_BENCHMARK.out.versions

    } else {

        error "Unknown --mode '${params.mode}'. Use 'production' or 'benchmark_defacing'."
    }


    /*
     * Combine all per-process versions.yml fragments into one file.
     *
     * A process may run once per subject and therefore emit the same version
     * fragment more than once. Deduplicating by file content prevents repeated
     * YAML entries in the final file.
     */
    versions_out = versions_source_out
        .unique { version_file -> version_file.text }
        .collectFile(
            name   : 'software_versions.yml',
            newLine: true,
            sort   : 'deep'
        )


    publish:
    merge_out       = merge_out
    config_out      = config_out
    bidsqc_out      = bidsqc_out
    bidsval_out     = bidsval_out
    bidsignore_out  = bidsignore_out
    mriqc_part_out  = mriqc_part_out
    mriqc_group_out = mriqc_group_out
    fmriprep_out    = fmriprep_out
    deface_out      = deface_out

    benchmark_metrics_out   = benchmark_metrics_out
    benchmark_qc_out        = benchmark_qc_out
    benchmark_files_out     = benchmark_files_out
    benchmark_summary_out   = benchmark_summary_out
    benchmark_defacedet_out = benchmark_defacedet_out

    // Publish the aggregated file at the root of the pipeline output directory.
    versions_out = versions_out
}


// Output specified in the same way as in the bash files.
output {

    // BIDS output
    merge_out {
        path { f -> f >> f.name }
    }

    // Publish modified config
    config_out {
        path { meta, f -> f >> f.name }
    }

    // BIDSGATE
    bidsqc_out {
        path { f -> f >> f.name }
    }

    // BIDSVALIDATOR
    bidsval_out {
        path { meta, f -> f >> f.name }
    }

    bidsignore_out {
        path { meta, f -> f >> f.name }
    }

    // MRIQC participant output -> derivatives/mriqc
    mriqc_part_out {
        path { x ->
            x.file >> "derivatives/mriqc/${x.rel}"
        }
    }

    // MRIQC group output -> derivatives/mriqc
    mriqc_group_out {
        path { x ->
            x.file >> "derivatives/mriqc/${x.rel}"
        }
    }

    // FMRIPREP output
    fmriprep_out {
        path { x ->
            x.file >> "derivatives/fmriprep/${x.rel}"
        }
    }

    // DEFACE output
    deface_out {
        path { x ->
            x.file >> "derivatives/defaces/${x.rel}"
        }
    }

    benchmark_metrics_out {
        path { f ->
            f >> "benchmark_defacing/metrics/${f.name}"
        }
    }

    benchmark_qc_out {
        path { f ->
            f >> "benchmark_defacing/qc/${f.name}"
        }
    }

    benchmark_summary_out {
        path { f ->
            f >> "benchmark_defacing/summary/${f.name}"
        }
    }

    benchmark_files_out {
        path 'benchmark_defacing/defaced'
    }

    // DEFACE DETECT output
    benchmark_defacedet_out {
        path { meta, qc_json, qc_pass ->
            qc_json >> "benchmark_defacedet/defacedet/${meta.deface_method ?: 'unknown'}/${qc_json.name}"
            qc_pass >> "benchmark_defacedet/defacedet/${meta.deface_method ?: 'unknown'}/${qc_pass.name}"
        }
    }

    /*
     * The collected file is already called software_versions.yml.
     * `path '.'` publishes it directly into the output root:
     *
     *   <outputDir>/software_versions.yml
     */
    versions_out {
        path '.'
    }
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/