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

## Getting started

1. Clone `dev` and record the commit used for your study.
2. Prepare a CSV with `project,dicom_dir`, a study-specific dcm2bids JSON configuration, the required ignore/allowlist files, and local container configuration.
3. Run conversion and validation, inspect the gate report, then resume through MRIQC, fMRIPrep, and defacing.

After completing the [setup instructions](docs/usage.md), the first run is:

```bash
# Run from the repository root; params.yaml and site.config are created in the guide.
nextflow run . -profile apptainer -c site.config -params-file params.yaml \
  -work-dir /scratch/neuromriprep-work \
  --stop_bidsval true --stop_mriqc true --stop_fmriprep true
```

Nextflow >=25.04.0 is required by the repository manifest. The current MRIQC wrappers invoke Apptainer directly, and fMRIPrep uses Apptainer/Singularity bind options. Merely selecting the Docker or Conda profile does not provide a portable full workflow.

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
