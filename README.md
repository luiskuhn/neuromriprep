<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/nf-core-neuromriprep_logo_dark.png">
    <img alt="neuromriprep" src="docs/images/nf-core-neuromriprep_logo_light.png">
  </picture>
</h1>

**neuromriprep** is a Nextflow DSL2 workflow for preparing structural and functional brain MRI data for research. It converts DICOM acquisitions to BIDS, validates the assembled dataset, runs MRIQC and fMRIPrep, and produces defaced anatomical images. A separate workflow compares four defacing methods on the same T1w images.

This repository is a development pipeline built from the nf-core template. The current `dev` implementation contains IRTG-specific paths and processing rules: a fresh clone requires local configuration and study inputs before it can run. Start with the [technical setup and usage guide](docs/usage.md); the bundled `test` profile still contains sequencing-template data and is not an MRI smoke test.

## Pipeline

![Metro diagram of DICOM conversion, BIDS validation and QC, MRIQC, fMRIPrep, and anatomical defacing, with automated stages and human review points.](docs/images/thesis-production-metro.png)

_Production workflow from Böhme (2026), Figure 3.1, printed p. 40. The thesis diagram shows PyDeface; the current production workflow allows four defacer choices. [Figure source details](docs/images/README.md)._

The three branches after the QC gate use the original merged BIDS dataset and can run concurrently. Defacing does not replace fMRIPrep inputs or anonymize every file in the results directory. The default stop flags enable conversion and validation only; use the [checkpoint guide](docs/production_workflow_guide.md) to review each stage before continuing.

## Example output

![Example PyDeface output showing sagittal, coronal, and axial slices of a defaced anatomical MRI.](docs/images/thesis-pydeface-example.png)

_Representative defaced anatomical image from Böhme (2026), Figure 3.2, printed p. 48. This illustrates the output appearance; every study still requires visual review for residual facial features and preservation of brain tissue. [Figure source details](docs/images/README.md)._

See the [output guide](docs/output.md) for result locations and the [defacing benchmark](docs/benchmark.md) for comparing methods.

## Step-by-step technical guide

The following example runs one study from DICOM to reviewed derivatives. Replace `/data`, `/srv`, and `/scratch` paths with paths accessible on your execution host and compute nodes. The current development code needs site-specific images and study configuration; completing these prerequisites is necessary before the commands can run.

### 1. Check prerequisites and clone the pipeline

Use Linux with Nextflow >=25.04.0, a compatible Java installation, and Apptainer. MRIQC invokes Apptainer directly, and fMRIPrep uses Apptainer/Singularity bind options; selecting Docker or Conda alone does not make the whole workflow portable.

```bash
java -version
nextflow -version
apptainer --version
git clone --branch dev https://github.com/luiskuhn/neuromriprep.git
cd neuromriprep
git rev-parse HEAD
```

Record the commit for reproducibility. Run all remaining Nextflow commands from this repository root. The bundled `test` and `test_full` profiles still contain template configuration and are not MRI smoke tests.

Prepare sufficient compute and scratch storage: the current settings request 16 CPUs/30 GB for MRIQC participant processing and 16 CPUs/60 GB per fMRIPrep task. Multiple branches may run concurrently. The merge task uses GNU `cp --reflink=always`, so the work filesystem must support reflinks; it has no ordinary-copy fallback. Test the chosen scratch location using small files:

```bash
mkdir -p /scratch/neuromriprep-work
printf 'reflink check\n' > /scratch/neuromriprep-work/reflink-source.txt
cp --reflink=always /scratch/neuromriprep-work/reflink-source.txt /scratch/neuromriprep-work/reflink-copy.txt
```

### 2. Organize the input DICOM data

Each input directory represents one participant/session. This is an illustrative layout; series subdirectory names are scanner-specific, while the participant/session directory basename is parsed by the pipeline:

```text
/data/study/
├── dicom/
│   ├── STUDY_001_S01/
│   │   ├── T1w_series/
│   │   │   ├── image0001.dcm
│   │   │   └── ...
│   │   ├── BOLD_series/
│   │   │   └── ...
│   │   └── fieldmap_series/
│   │       └── ...
│   └── STUDY_002_S01/
│       └── ...
├── samplesheet.csv
├── dcm2bids_config.json
├── bids_filter.json
└── license.txt
```

Use actual DICOM files, not an existing BIDS or NIfTI-only dataset: the current entry workflow does not expose a BIDS-input mode. The conversion configuration maps scanner series to BIDS entities; folder names such as `T1w_series` do not perform that mapping by themselves.

The parser splits the input directory basename on `_`. The second component is the subject; the third must contain `S` followed by the session number. Thus `STUDY_001_S01` becomes `sub-001/ses-01`. Use a study prefix without underscores, subject labels without `sub-`, and unambiguous session names. Missing/unrecognized components can silently fall back to subject `unknown` or session `01`. Avoid whitespace in paths for the current shell wrappers.

### 3. Create the samplesheet and study configuration

Save this CSV as `/data/study/samplesheet.csv`, using real absolute paths:

```csv
project,dicom_dir
STUDY,/data/study/dicom/STUDY_001_S01
STUDY,/data/study/dicom/STUDY_002_S01
```

| Column      | Required content                                                            |
| ----------- | --------------------------------------------------------------------------- |
| `project`   | Study label carried in metadata; all rows are merged into one dataset.      |
| `dicom_dir` | Existing directory containing one participant/session's DICOM acquisitions. |

Use one study per run and no duplicate participant/session rows. Start with a small representative subset. Before using multiple sessions for the same subject with fMRIPrep, resolve the [current duplicate-task limitation](docs/pipeline.md#current-development-limitations): its wrapper does not deduplicate participant jobs across input rows.

Prepare `/data/study/dcm2bids_config.json` using your scanner protocol. It must contain a `descriptions` array defining series matching, BIDS datatypes/suffixes/entities, and the appropriate field-map associations. Obtain a reviewed study mapping from your site maintainer; a generic mapping is not sufficient. The pipeline modifies field-map identifiers per session and applies [study-specific postprocessing](docs/pipeline.md#production-stages), which you must check against your acquisitions.

For fMRIPrep, obtain a valid FreeSurfer license at `/data/study/license.txt`. Create `/data/study/bids_filter.json` containing `{}` for an unrestricted filter, or provide a reviewed filter for the intended acquisitions. An explicit filter avoids the missing default `assets/empty_bids_filter.json` and site-specific `ses01`/`ses02` aliases.

### 4. Create the local validation policies

From the repository root, create these files if they do not exist (the directory is Git-ignored):

```bash
mkdir -p assets/input_pipeline
touch assets/input_pipeline/bidsignore_list.txt
touch assets/input_pipeline/bidsignore_remove.txt
touch assets/input_pipeline/bidsval_allowlist.txt
```

Use one pattern per line in `bidsignore_list.txt` to exclude a path from validation; use one exact entry per line in `bidsignore_remove.txt` to remove an exclusion. In `bidsval_allowlist.txt`, list only warning codes you have reviewed and accepted. Empty files start with no exceptions. Errors cannot be allowlisted, and an exception does not repair the underlying data.

### 5. Configure containers and resources

Save the following as `site.config` in the repository root, replacing the example paths with existing images and a populated TemplateFlow cache. Obtain the required SIF images from your site maintainer; this repository does not ship portable builds of all custom images. The helper image needs Bash, jq, and GNU coreutils; the validator image needs Bash and `bids-validator`.

```groovy
process {
    withName: 'DCM2BIDS_CONFIG|DCM2BIDS_POSTPROC|MERGE_BIDS_DATASET|BIDSIGNORE' {
        ext.container = '/srv/containers/docker-curl-jq.sif'
    }
    withName: 'DCM2BIDS|DCM2BIDS_OUTPUT_PATCH' {
        ext.container = '/srv/containers/dcm2bids_3.2.0.sif'
    }
    withName: 'BIDS_VALIDATOR' {
        ext.container = '/srv/containers/bidsvalidator_bash.sif'
    }
    withName: 'BIDS_QC_GATE' {
        ext.container = '/srv/containers/python_3.11.14-trixie.sif'
    }
    withName: 'FMRIPREP' {
        ext.container = '/srv/containers/fmriprep_24.1.1.sif'
        ext.templateflow_host = '/srv/templateflow'
        cpus = 16
        memory = '60 GB'
        maxForks = 1
    }
    withName: 'PYDEFACE' {
        ext.container = '/srv/containers/pydeface_3.0.sif'
        maxForks = 1
    }
    withName: 'MRIQC_PARTICIPANT' {
        cpus = 16
        memory = '30 GB'
    }
}
```

Most declared `*_container` parameters are not wired into their modules; use the process `ext.container` settings above. MRIQC participant processing instead uses `mriqc_container` in the parameter file below. **MRIQC group processing still hard-codes `/nic/sw/IRTG/sif/mriqc_25.0.0rc0.sif`**: that image must exist at that path on the execution host, or the wrapper must be adapted before running MRIQC at another site. Changing `mriqc_container` alone does not fix the group stage.

Ensure the TemplateFlow cache contains the references needed for the requested output spaces. For HPC execution, add your scheduler executor, queue/account, and storage bindings to `site.config`; otherwise tasks run locally. The example limits fMRIPrep concurrency to one task, but other branches can still run alongside it.

### 6. Save the run parameters

Save this as `params.yaml` in the repository root, replacing the example paths:

```yaml
mode: production
input: /data/study/samplesheet.csv
outdir: /data/study/results
dcm2bids_config: /data/study/dcm2bids_config.json
bids_qc_allowlist: assets/input_pipeline/bidsval_allowlist.txt
enforce_bidsqc_gate: true
stop_bidsval: true
stop_mriqc: true
stop_fmriprep: true
skip_mriqc: false
skip_fmriprep: false
mriqc_vpn_file: null
fmriprep_vpn_file: null
pydeface_vpn_file: null
mriqc_container: /srv/containers/mriqc_25.0.0rc0.sif
fmriprep_fs_license: /data/study/license.txt
fmriprep_bids_filter: /data/study/bids_filter.json
ignore_fmriprep_fail: false
deface_tool: pydeface
```

The null participant lists select all available participants for each branch and override missing institutional list files. The example opts out of the default behavior that can ignore fMRIPrep failures. Production defacers are `pydeface`, `mri_deface`, `fsl_deface`, and `afni_refacer`; alternatives need their own image and reference configuration. See the [parameter reference](docs/usage.md#operational-parameter-reference).

Check configuration resolution before processing data:

```bash
nextflow config . -profile apptainer -c site.config -flat > resolved.config.txt
```

Inspect the process overrides. This does not validate your DICOM mapping, image availability, or successful pipeline execution.

### 7. Convert DICOM to BIDS and review validation

```bash
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work \
  --stop_bidsval true --stop_mriqc true --stop_fmriprep true
```

Under `/data/study/results`, inspect `sub-*/ses-*/`, `dataset_validation_log.txt`, and `bids_qc_summary.txt`. Check acquisition completeness and field-map associations, and require `check_passed: True` before continuing. A rejected gate filters downstream data and can still leave a successful Nextflow exit. Fix source data/configuration and rerun with `-resume`; do not assume edits to published results will be used by cached upstream tasks.

### 8. Run MRIQC and inspect image quality

```bash
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work -resume \
  --stop_bidsval false --stop_mriqc true --stop_fmriprep true
```

Review participant HTML reports, image-quality metrics, and group reports under `derivatives/mriqc/`. Assess artifacts, motion, coverage, and outliers for your study; MRIQC does not automatically exclude scans. Keep both skip flags false and `stop_fmriprep` true here: `stop_mriqc` alone does not block the independent defacing branch.

### 9. Run fMRIPrep and inspect preprocessing

```bash
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work -resume \
  --stop_bidsval false --stop_mriqc false --stop_fmriprep true
```

Review HTML reports under `derivatives/fmriprep/`, including registration, normalization, segmentation, functional preprocessing, and confounds. Confirm that every requested participant completed before moving on.

### 10. Deface anatomical images and review the results

```bash
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work -resume \
  --stop_bidsval false --stop_mriqc false --stop_fmriprep false \
  --deface_tool pydeface
```

Inspect `derivatives/defaces/sub-*/ses-*/anat/` for residual facial features and unintended brain-tissue removal. Production does not automatically run the benchmark's renderer or detector. Original BIDS images and other outputs remain present; defacing these copies does not make the whole result directory ready for public sharing.

All three downstream branches consume the same merged BIDS dataset. Setting all stop flags false on a fresh run enables concurrent branches, without intermediate human review. The staged commands above implement review by resuming after each inspection. Keep the same launch directory, `.nextflow/` cache, and work directory for `-resume`.

Retain the commit, parameter/configuration files, image identities, and reports with your study. See [output diagnostics and execution reports](docs/output.md), [alternative stop/skip combinations](docs/production_workflow_guide.md#other-execution-patterns), and [troubleshooting](docs/usage.md#troubleshooting-and-reproducibility).

## Documentation

- [Documentation index](docs/README.md)
- [Technical setup, inputs, configuration, and troubleshooting](docs/usage.md)
- [Step-by-step production runs and review checkpoints](docs/production_workflow_guide.md)
- [Pipeline architecture and thesis context](docs/pipeline.md)
- [Outputs and quality-control review](docs/output.md)
- [Defacing benchmark](docs/benchmark.md)

## Credits and references

Contributors include Luis, Mahnaz, Carolin Schwitalla, and Lorena Böhme. This documentation draws on Böhme's 2026 master's thesis, _neuromriprep: A Nextflow Pipeline for Reproducible Preprocessing and Anonymization for Functional MRI Data_, and checks operational details against the current source. See [source notes and limitations](docs/pipeline.md#thesis-and-source-notes) and [tool citations](CITATIONS.md). Cite the tools actually used and record the pipeline commit and container versions; this development repository does not declare a pipeline DOI.

For bugs or questions, [open an issue](https://github.com/luiskuhn/neuromriprep/issues). See the [contribution guidelines](docs/CONTRIBUTING.md) and [MIT license](LICENSE).
