include { DCM2BIDS            } from '../modules/local/dcm2bids'
include { DCM2BIDS_CONFIG     } from '../modules/local/dcm2bidsconfig'
include { DCM2BIDS_POSTPROC   } from '../modules/local/dcm2bidspostprocess'
include { MERGE_BIDS_DATASET  } from '../modules/local/mergebidsdataset'
include { BIDSIGNORE          } from '../modules/local/bidsignore'
include { BIDS_VALIDATOR      } from '../modules/local/bidsvalidator'

include { PYDEFACE            } from '../modules/local/pydeface'
include { MRI_DEFACE          } from '../modules/local/mrideface'
include { FSL_DEFACE          } from '../modules/local/fsldeface'
include { AFNI_REFACER        } from '../modules/local/afnirefacer'

include { DEFACE_QC_RENDER    } from '../modules/local/defaceqcrender'
include { DEFACE_METRICS      } from '../modules/local/defacemetrics'
include { DEFACE_DETECTOR     } from '../modules/local/defacedetector'
include { MERGE_BENCHMARK     } from '../modules/local/mergebenchmark'


def stripNii(f) {
    def n = f.name
    n = n.replaceFirst(/\.nii\.gz$/, '')
    n = n.replaceFirst(/\.nii$/, '')
    return n
}


def normalizeDetectorImageName(p) {
    def n = p.name
    n = n.replaceFirst(/\.deface_qc\.json$/, '')
    n = n.replaceFirst(/\.json$/, '')
    n = n.replaceFirst(/_defaced$/, '')
    return n
}


def relFromSub(p) {
    def s = p.toString()
    def parts = s.split(/[\\\/]+/)
    def i = parts.findIndexOf { part -> part.startsWith('sub-') }

    if (i < 0) {
        throw new IllegalArgumentException("Could not derive rel path from: ${s}")
    }

    return parts[i..-1].join('/')
}


workflow DEFACE_BENCHMARK {

    take:
    ch_samplesheet
    ch_config

    main:

    ch_input = ch_samplesheet
        .map { meta, dicom_dir ->
            def folder_name = dicom_dir.name
            def parts       = folder_name.split('_')
            def subject     = parts.size() > 1 ? parts[1] : "unknown"
            def sesStr      = parts.size() > 2 ? parts[2] : ""
            def ses_match   = sesStr =~ /S(\d+)/
            def ses         = ses_match ? ses_match[0][1] : "01"
            def session     = ses.padLeft(2, '0')

            def new_meta = meta + [
                subject: subject,
                session: session,
                project: meta.project
            ]

            tuple(new_meta, dicom_dir)
        }

    ch_cfg_in = ch_input
        .combine(ch_config)
        .map { meta, dicom_dir, config_file ->
            tuple(meta, config_file)
        }

    DCM2BIDS_CONFIG(ch_cfg_in)

    ch_run_in = ch_input
        .join(DCM2BIDS_CONFIG.out.config)
        .map { row ->
            def meta            = row[0]
            def dicom_dir       = row[1]
            def modified_config = row[2]

            tuple(meta, dicom_dir, modified_config)
        }

    ch_force = Channel.value(params.force_dcm2bids ?: false)

    DCM2BIDS(ch_run_in, ch_force)
    DCM2BIDS_POSTPROC(DCM2BIDS.out.bids_output)

    ch_sub_dirs     = DCM2BIDS_POSTPROC.out.bids_sub.map { meta, subdir -> subdir }.collect()
    ch_dwi_adc_dirs = DCM2BIDS_POSTPROC.out.dwi_adc_sub.map { meta, ddir -> ddir }.collect()
    ch_logs         = DCM2BIDS.out.log.collect()

    MERGE_BIDS_DATASET(ch_sub_dirs, ch_dwi_adc_dirs, ch_logs)

    ch_bids_dataset = MERGE_BIDS_DATASET.out.bids_dataset

    ch_dataset_meta = ch_samplesheet
        .map { meta, ignored -> meta }
        .first()
        .map { meta -> meta + [ id: 'dataset' ] }

    // Read in ignore files, same pattern as NEUROMRIPREP
    ch_ignore_add = Channel.value(file('assets/input_pipeline/bidsignore_list.txt', checkIfExists: true))
    ch_ignore_remove = Channel.value(file('assets/input_pipeline/bidsignore_remove.txt', checkIfExists: true))

    ch_bidsignore_in = ch_dataset_meta
        .combine(ch_bids_dataset)
        .map { meta, ds ->
            tuple(meta, ds)
        }

    BIDSIGNORE(
        ch_bidsignore_in,
        ch_ignore_add,
        ch_ignore_remove
    )

    ch_bidsignore_dataset = BIDSIGNORE.out.bids_dataset
    ch_bidsignore         = BIDSIGNORE.out.bidsignore_file

    ch_bidsval_in = ch_bidsignore_dataset
        .join(ch_bidsignore)

    BIDS_VALIDATOR(ch_bidsval_in)

    ch_bids_dataset_after_ignore = ch_bidsignore_dataset
        .map { meta, outdir ->
            outdir
        }
        .first()

    qc_script      = file("${projectDir}/assets/scripts/deface_qc_render.py")
    metrics_script = file("${projectDir}/assets/scripts/deface_metrics.py")
    merge_script   = Channel.value(file("${projectDir}/assets/scripts/merge_benchmark.py"))

    detector_script   = Channel.value(file("${projectDir}/assets/scripts/mri_deface_detector.mjs"))
    detector_modeldir = Channel.value(file("${projectDir}/assets/mri-deface-detector/model_js"))

    // Original T1w inputs only
    ch_benchmark_in = ch_input
        .map { meta, ignored -> meta }
        .combine(ch_bids_dataset_after_ignore)
        .flatMap { meta, ds ->
            def anatDir = new File(ds.toString(), "sub-${meta.subject}/ses-${meta.session}/anat")

            if (!anatDir.exists()) {
                return []
            }

            def niiFiles = anatDir
                .listFiles()
                ?.findAll { f ->
                    def n = f.name
                    n.endsWith('.nii.gz') &&
                    !n.contains('_defaced') &&
                    (n ==~ /.*_T1w\.nii(\.gz)?$/)
                }
                ?: []

            niiFiles.collect { f ->
                tuple(meta, ds, f.toPath())
            }
        }

    // Run all 4 defacers
    PYDEFACE(ch_benchmark_in)
    MRI_DEFACE(ch_benchmark_in)
    FSL_DEFACE(ch_benchmark_in)
    AFNI_REFACER(ch_benchmark_in)

    // Originals keyed
    ch_orig_keyed = ch_benchmark_in
        .map { meta, ds, orig_nifti ->
            def key = "${meta.subject}|${meta.session}|${stripNii(orig_nifti)}"
            tuple(key, meta, orig_nifti)
        }

    // Defaced outputs keyed
    ch_pydeface_keyed = PYDEFACE.out.defaced
        .map { meta, defaced_nifti ->
            def base = stripNii(defaced_nifti).replaceFirst(/_defaced$/, '')
            def key  = "${meta.subject}|${meta.session}|${base}"

            tuple(key, meta + [ deface_method: 'pydeface' ], 'pydeface', defaced_nifti)
        }

    ch_mri_deface_keyed = MRI_DEFACE.out.defaced
        .map { meta, defaced_nifti ->
            def base = stripNii(defaced_nifti).replaceFirst(/_defaced$/, '')
            def key  = "${meta.subject}|${meta.session}|${base}"

            tuple(key, meta + [ deface_method: 'mri_deface' ], 'mri_deface', defaced_nifti)
        }

    ch_fsl_deface_keyed = FSL_DEFACE.out.defaced
        .map { meta, defaced_nifti ->
            def base = stripNii(defaced_nifti).replaceFirst(/_defaced$/, '')
            def key  = "${meta.subject}|${meta.session}|${base}"

            tuple(key, meta + [ deface_method: 'fsl_deface' ], 'fsl_deface', defaced_nifti)
        }

    ch_afni_refacer_keyed = AFNI_REFACER.out.defaced
        .map { meta, defaced_nifti ->
            def base = stripNii(defaced_nifti).replaceFirst(/_defaced$/, '')
            def key  = "${meta.subject}|${meta.session}|${base}"

            tuple(key, meta + [ deface_method: 'afni_refacer' ], 'afni_refacer', defaced_nifti)
        }

    // QC inputs per method, then mix
    ch_deface_qc_py = ch_orig_keyed
        .join(ch_pydeface_keyed)
        .map { key, meta_orig, orig_nifti, meta_def, method, defaced_nifti ->
            tuple(meta_def, method, qc_script, orig_nifti, defaced_nifti)
        }

    ch_deface_qc_mri = ch_orig_keyed
        .join(ch_mri_deface_keyed)
        .map { key, meta_orig, orig_nifti, meta_def, method, defaced_nifti ->
            tuple(meta_def, method, qc_script, orig_nifti, defaced_nifti)
        }

    ch_deface_qc_fsl = ch_orig_keyed
        .join(ch_fsl_deface_keyed)
        .map { key, meta_orig, orig_nifti, meta_def, method, defaced_nifti ->
            tuple(meta_def, method, qc_script, orig_nifti, defaced_nifti)
        }

    ch_deface_qc_afni = ch_orig_keyed
        .join(ch_afni_refacer_keyed)
        .map { key, meta_orig, orig_nifti, meta_def, method, defaced_nifti ->
            tuple(meta_def, method, qc_script, orig_nifti, defaced_nifti)
        }

    ch_deface_qc_in = Channel
        .empty()
        .mix(ch_deface_qc_py)
        .mix(ch_deface_qc_mri)
        .mix(ch_deface_qc_fsl)
        .mix(ch_deface_qc_afni)

    DEFACE_QC_RENDER(ch_deface_qc_in)

    // Metrics inputs per method, then mix
    ch_deface_metrics_py = ch_orig_keyed
        .join(ch_pydeface_keyed)
        .map { key, meta_orig, orig_nifti, meta_def, method, defaced_nifti ->
            tuple(meta_def, method, metrics_script, orig_nifti, defaced_nifti)
        }

    ch_deface_metrics_mri = ch_orig_keyed
        .join(ch_mri_deface_keyed)
        .map { key, meta_orig, orig_nifti, meta_def, method, defaced_nifti ->
            tuple(meta_def, method, metrics_script, orig_nifti, defaced_nifti)
        }

    ch_deface_metrics_fsl = ch_orig_keyed
        .join(ch_fsl_deface_keyed)
        .map { key, meta_orig, orig_nifti, meta_def, method, defaced_nifti ->
            tuple(meta_def, method, metrics_script, orig_nifti, defaced_nifti)
        }

    ch_deface_metrics_afni = ch_orig_keyed
        .join(ch_afni_refacer_keyed)
        .map { key, meta_orig, orig_nifti, meta_def, method, defaced_nifti ->
            tuple(meta_def, method, metrics_script, orig_nifti, defaced_nifti)
        }

    ch_deface_metrics_in = Channel
        .empty()
        .mix(ch_deface_metrics_py)
        .mix(ch_deface_metrics_mri)
        .mix(ch_deface_metrics_fsl)
        .mix(ch_deface_metrics_afni)

    DEFACE_METRICS(ch_deface_metrics_in)

    // Metric manifest for merge
    ch_metric_manifest = DEFACE_METRICS.out.metrics_publish
        .map { x -> x instanceof List ? x[-1] : x }
        .map { p -> p.toString() + '\n' }
        .collectFile(name: 'metric_files.txt', keepHeader: false, newLine: false)

    // Detector inputs per method
    ch_pydeface_t1w = PYDEFACE.out.defaced
        .filter { meta, f -> f.name ==~ /.*_T1w_defaced\.nii(\.gz)?$/ }
        .map { meta, f -> tuple(meta + [ deface_method: 'pydeface' ], f) }

    ch_mri_deface_t1w = MRI_DEFACE.out.defaced
        .filter { meta, f -> f.name ==~ /.*_T1w_defaced\.nii(\.gz)?$/ }
        .map { meta, f -> tuple(meta + [ deface_method: 'mri_deface' ], f) }

    ch_fsl_deface_t1w = FSL_DEFACE.out.defaced
        .filter { meta, f -> f.name ==~ /.*_T1w_defaced\.nii(\.gz)?$/ }
        .map { meta, f -> tuple(meta + [ deface_method: 'fsl_deface' ], f) }

    ch_afni_refacer_t1w = AFNI_REFACER.out.defaced
        .filter { meta, f -> f.name ==~ /.*_T1w_defaced\.nii(\.gz)?$/ }
        .map { meta, f -> tuple(meta + [ deface_method: 'afni_refacer' ], f) }

    ch_all_detector_in = Channel
        .empty()
        .mix(ch_pydeface_t1w)
        .mix(ch_mri_deface_t1w)
        .mix(ch_fsl_deface_t1w)
        .mix(ch_afni_refacer_t1w)

    DEFACE_DETECTOR(ch_all_detector_in, detector_script, detector_modeldir)

    // Detector manifest with explicit metadata so merge can attach scores/pass to the right row
    ch_detector_manifest = DEFACE_DETECTOR.out.qc_json
        .map { meta, f ->
            def image_name = normalizeDetectorImageName(f)
            "${meta.subject}\t${meta.session}\t${meta.deface_method}\t${image_name}\t${f.toString()}\n"
        }
        .collectFile(name: 'detector_manifest.tsv', keepHeader: false, newLine: false)

    MERGE_BENCHMARK(ch_metric_manifest, ch_detector_manifest, merge_script)

    defacedet_out = DEFACE_DETECTOR.out.qc_json.join(DEFACE_DETECTOR.out.qc_pass)

    // Publish defaced files under method-specific subfolders
    ch_all_defaced_publish = Channel
        .empty()
        .mix(
            PYDEFACE.out.defaced_publish
                .flatten()
                .map { p -> [ file: p, rel: "pydeface/${relFromSub(p)}" ] }
        )
        .mix(
            MRI_DEFACE.out.defaced_publish
                .flatten()
                .map { p -> [ file: p, rel: "mri_deface/${relFromSub(p)}" ] }
        )
        .mix(
            FSL_DEFACE.out.defaced_publish
                .flatten()
                .map { p -> [ file: p, rel: "fsl_deface/${relFromSub(p)}" ] }
        )
        .mix(
            AFNI_REFACER.out.defaced_publish
                .flatten()
                .map { p -> [ file: p, rel: "afni_refacer/${relFromSub(p)}" ] }
        )

    emit:
    benchmark_defaced   = ch_all_defaced_publish
    benchmark_qc        = DEFACE_QC_RENDER.out.qc_publish
    benchmark_metrics   = MERGE_BENCHMARK.out.per_subject_method_table
    benchmark_summary   = MERGE_BENCHMARK.out.summary_table
    benchmark_defacedet = defacedet_out
    versions            = DCM2BIDS.out.versions
}