<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/nf-core-neuromriprep_logo_dark.png">
    <img alt="neuromriprep" src="docs/images/nf-core-neuromriprep_logo_light.png">
  </picture>
</h1>

**neuromriprep** is a Nextflow DSL2 workflow for preparing structural and functional brain MRI data for research. It converts DICOM acquisitions to BIDS, validates the assembled dataset, runs MRIQC and fMRIPrep, and produces defaced anatomical images. A separate workflow compares four defacing methods on the same T1w images.

This development pipeline follows nf-core design principles but is not an nf-core release. The `dev` branch requires site-specific configuration and study inputs; follow the guide below before running.

## FAIR research data management context

[Sezer et al. (2026)](https://doi.org/10.5281/zenodo.22099332) describe the IRTG 2804 infrastructure built by QBiC and collaborators on the **de.NBI Cloud**, and identify neuromriprep as an MRI workflow use case. The architecture combines controlled-access computation, OMERO image management, linked study metadata, and containerized Nextflow workflows. Here, neuromriprep provides MRI conversion, validation, preprocessing, and defacing; storage, access control, and metadata services belong to the surrounding infrastructure.

This approach aligns with **NFDI4BIOIMAGE** goals for interoperable formats, metadata, and reproducible image analysis. That is a conceptual alignment: the paper describes a de.NBI/QBiC deployment, not an NFDI-operated service. See [NFDI’s consortium overview](https://www.nfdi.de/consortia-nfdi4bioimage/?lang=en), [workflow/infrastructure boundaries](docs/pipeline.md#fair-oriented-infrastructure-and-nfdi-context), and the [full citation](CITATIONS.md#fair-oriented-research-data-management).

## Pipeline

![Metro diagram of DICOM conversion, BIDS validation and QC, MRIQC, fMRIPrep, and anatomical defacing, with automated stages and human review points.](docs/images/thesis-production-metro.png)

_Production workflow from Böhme (2026), Figure 3.1, printed p. 40. The thesis diagram shows PyDeface; the current production workflow allows four defacer choices. [Figure source details](docs/images/README.md)._

MRIQC, fMRIPrep, and defacing branch from the merged BIDS dataset and can run concurrently. Default stop flags enable conversion and validation only; the staged commands below provide review checkpoints.

## Example output

![Example PyDeface output showing sagittal, coronal, and axial slices of a defaced anatomical MRI.](docs/images/thesis-pydeface-example.png)

_PyDeface example from Böhme (2026), Figure 3.2, printed p. 48: sagittal, coronal, and axial slices. [Figure source details](docs/images/README.md)._

## Step-by-step technical guide

Replace `/data`, `/srv`, and `/scratch` with paths accessible on your execution host and compute nodes. Run commands from the cloned repository root.

### 1. Check prerequisites and clone the pipeline

Use Linux, Nextflow >=25.04.0, compatible Java, and Apptainer. The MRIQC/fMRIPrep wrappers require Apptainer-style execution; Docker or Conda alone is insufficient.

```bash
java -version
nextflow -version
apptainer --version
git clone --branch dev https://github.com/luiskuhn/neuromriprep.git
cd neuromriprep
git rev-parse HEAD
```

Record the commit. The bundled `test`/`test_full` profiles are template configurations, not MRI smoke tests.

Defaults request 16 CPUs/30 GB for MRIQC participant processing and 16 CPUs/60 GB per fMRIPrep task. Allow for concurrent branches. Dataset assembly requires GNU `cp --reflink=always`; test your scratch filesystem (there is no copy fallback):

```bash
mkdir -p /scratch/neuromriprep-work
printf 'reflink check\n' > /scratch/neuromriprep-work/reflink-source.txt
cp --reflink=always /scratch/neuromriprep-work/reflink-source.txt /scratch/neuromriprep-work/reflink-copy.txt
```

### 2. Organize the input DICOM data

Use one DICOM directory per participant/session. Series subdirectories are illustrative and scanner-specific:

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

The entry workflow accepts DICOM, not existing BIDS/NIfTI datasets. Series-to-BIDS mapping comes from the conversion configuration, not the series folder names.

Names must follow `STUDY_001_S01` → `sub-001/ses-01`: the second underscore-separated component is the subject, and the third contains `S` plus session digits. Avoid underscores in the study prefix, `sub-` in the subject component, and whitespace in paths. Malformed names can silently become subject `unknown` or session `01`.

### 3. Create the samplesheet and study configuration

Save this CSV as `/data/study/samplesheet.csv`, using real absolute paths:

```csv
project,dicom_dir
STUDY,/data/study/dicom/STUDY_001_S01
STUDY,/data/study/dicom/STUDY_002_S01
```

All rows form one study dataset. Start small, avoid duplicate participant/session rows, and resolve the [fMRIPrep duplicate-task limitation](docs/pipeline.md#current-development-limitations) before processing multiple sessions per subject.

Obtain a reviewed `dcm2bids_config.json` for your scanner protocol. Its `descriptions` array defines series matching, BIDS entities, and field-map associations. Check the pipeline’s [session-specific field-map edits and postprocessing](docs/pipeline.md#production-stages) against your acquisitions.

For fMRIPrep, provide a valid FreeSurfer `license.txt` and `bids_filter.json` (`{}` for unrestricted input, or a reviewed acquisition filter). The default filter is absent; the `ses01`/`ses02` aliases use institutional paths.

### 4. Create the local validation policies

Create the required files without overwriting existing policies (this directory is Git-ignored):

```bash
mkdir -p assets/input_pipeline
touch assets/input_pipeline/bidsignore_list.txt
touch assets/input_pipeline/bidsignore_remove.txt
touch assets/input_pipeline/bidsval_allowlist.txt
```

Use one entry per line: `bidsignore_list.txt` adds validation exclusions; `bidsignore_remove.txt` removes exact entries; `bidsval_allowlist.txt` accepts reviewed warning codes. Empty files mean no exceptions. Errors cannot be allowlisted.

### 5. Configure containers and resources

Save as `site.config`, using existing SIF images from your site maintainer and a populated TemplateFlow cache. The helper image needs Bash, jq, and GNU coreutils; the validator needs Bash and `bids-validator`.

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

Use `ext.container`; most declared `*_container` parameters are unwired. MRIQC participant uses `mriqc_container` below, but **MRIQC group hard-codes `/nic/sw/IRTG/sif/mriqc_25.0.0rc0.sif`**. Provide that image at that path or adapt the wrapper; changing the participant parameter does not fix group processing.

For HPC, add the scheduler executor, queue/account, and storage bindings; otherwise execution is local. This example limits fMRIPrep to one concurrent task.

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

Null lists select all participants and override missing institutional files. `ignore_fmriprep_fail: false` makes failures terminate the run. Alternative defacers (`mri_deface`, `fsl_deface`, `afni_refacer`) require corresponding images/references; see the [parameter reference](docs/usage.md#operational-parameter-reference).

Resolve and inspect the configuration before running:

```bash
nextflow config . -profile apptainer -c site.config -flat > resolved.config.txt
```

This checks configuration resolution, not data or image availability.

### 7. Convert DICOM to BIDS and review validation

```bash
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work \
  --stop_bidsval true --stop_mriqc true --stop_fmriprep true
```

In `/data/study/results`, check `sub-*/ses-*/`, field-map associations, `dataset_validation_log.txt`, and `bids_qc_summary.txt`. Require `check_passed: True`: gate rejection can still yield a successful Nextflow exit. Correct source inputs/configuration, not published copies, then rerun with `-resume`.

### 8. Run MRIQC and inspect image quality

```bash
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work -resume \
  --stop_bidsval false --stop_mriqc true --stop_fmriprep true
```

Review reports and metrics in `derivatives/mriqc/` for artifacts, motion, coverage, and outliers; scans are not automatically excluded. Keep both skip flags false and `stop_fmriprep` true: `stop_mriqc` alone does not block defacing.

### 9. Run fMRIPrep and inspect preprocessing

```bash
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work -resume \
  --stop_bidsval false --stop_mriqc false --stop_fmriprep true
```

Review `derivatives/fmriprep/` reports for registration, normalization, segmentation, and confounds. Confirm completion for every requested participant.

### 10. Deface anatomical images and review the results

```bash
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work -resume \
  --stop_bidsval false --stop_mriqc false --stop_fmriprep false \
  --deface_tool pydeface
```

Inspect `derivatives/defaces/sub-*/ses-*/anat/` for residual facial features and lost brain tissue. Original BIDS images remain; review the specific files intended for sharing. Production does not run the benchmark renderer/detector.

For `-resume`, retain the launch directory, `.nextflow/` cache, and work directory. Enabling all stages on a fresh run permits concurrent processing without review pauses.

Archive the commit, parameters/configuration, image identities, and reports. Consult [output diagnostics](docs/output.md), [stop/skip combinations](docs/production_workflow_guide.md#other-execution-patterns), and [troubleshooting](docs/usage.md#troubleshooting-and-reproducibility).

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
