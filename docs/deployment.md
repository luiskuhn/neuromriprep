# Deployment: clinical SIF installations and portable Docker sites

This guide complements [technical usage](usage.md) and the [production checkpoints](production_workflow_guide.md). It documents deployment choices; it does not change the clinical workflow or promise that every module is runtime-independent.

## Clinical deployment is the primary operating context

neuromriprep was developed for [IRTG-2804](https://irtg2804.de/), an international research training group studying women's mental health across reproductive transitions. In its University Hospital clinical deployment, processing must remain within the approved clinical network. Internet and data access are restricted; container images are supplied as IT-approved local `.sif` files. Do not replace these images with public registry downloads on clinical systems or move patient data outside that environment to solve an installation problem.

Apptainer/Singularity is the approved runtime in this setting. Its adoption reflects institutional security and operational policy; it is not a blanket claim that one runtime makes patient data secure. Follow local IT requirements for runtime version, image provenance, privileges, bind mounts, storage and network access. The current wrappers invoke `apptainer` explicitly in some stages, so a machine exposing only a `singularity` executable needs an IT-approved compatibility arrangement.

An international collaborating site may permit Docker. That is a separate deployment decision, not permission to export clinical data. Establish the receiving site's authorization, data-transfer agreement and approved storage before transferring inputs. Defacing alone does not authorize public redistribution or remove identifying metadata.

## What can actually be configured?

| Stage | Current image mechanism | Portability boundary |
| --- | --- | --- |
| Conversion, helper steps, BIDS validator and QC gate | Process-specific `task.ext.container` | Set a local SIF path or a suitable Docker image through `withName`; each image must contain the tools called by that module. |
| PyDeface | `task.ext.container` | Same override mechanism; image must expose PyDeface, FSL and its runtime environment to a non-interactive task shell. |
| fMRIPrep | `task.ext.container`, `ext.templateflow_host` | Image configurable, but module `containerOptions` uses Apptainer `--cleanenv -B` syntax. Image substitution alone is insufficient for Docker. License and reference cache remain required. |
| MRIQC participant | `params.mriqc_container` inside `apptainer run` | Selecting the Docker profile does not replace this nested Apptainer command. |
| MRIQC group | Embedded `apptainer run` and institutional SIF path | Not fully site-configurable in the current wrapper. The approved path must exist, or a future separately reviewed change is needed. |

Many top-level `*_container` parameters are declared but not consumed by the corresponding modules. Use the source-backed overrides in [usage](usage.md#5-configure-images-resources-and-reference-data); do not assume a plausible parameter name changes an image. Benchmark modules require their own audit and are outside the Docker route below.

## Preparing a restricted-network installation

Coordinate preparation on an approved connected staging system, then transfer artifacts through the institution's permitted mechanism. Patient data is not needed to build containers.

Prepare and record:

- The exact pipeline commit, Nextflow version/distribution and compatible Java runtime.
- Approved SIF images, SHA-256 checksums, actual executable versions and build/provenance records. A SIF filename is not a version guarantee.
- Any Nextflow plugins, configuration includes or other resources needed at runtime. Prefetch them using the intended versions and user/cache layout; an existing executable alone does not establish offline readiness.
- Complete reference caches for enabled stages, including TemplateFlow resources and the FreeSurfer license where applicable. Mount reference data read-only where supported; keep required writable caches inside approved storage.
- Site policy files, samplesheets and protocol mappings, with all paths visible from the execution nodes.

On the clinical execution system, use local paths rather than `docker://`, `oras://` or registry references. Test with outbound access restricted as it will be in production. `NXF_OFFLINE=true` can prevent Nextflow from fetching missing resources, but it does not populate caches and is not a firewall for software inside containers. Keep MRIQC's existing `--no-sub` behavior. Site network controls remain authoritative.

The `apptainer pull` examples elsewhere in these docs are **connected preparation examples only**, subject to IT approval; they are not instructions to pull images inside the restricted clinical network.

## Portable Docker route: conversion, validation and PyDeface

This route was exercised on a native Linux x86-64 host. MRIQC and fMRIPrep were disabled. Docker Desktop on Apple silicon was also exercised with amd64 emulation, but its performance is not representative of native Linux.

### Preconditions before claiming an unchanged-source deployment

The study checkout used for that experience included portability fixes: the merge module's `cp --reflink=always` was changed to `--reflink=auto`, and a stray standalone token in its configuration snapshot was removed. These are **not runtime profile settings**, and are not applied by this documentation. The unmodified branch still needs its documented reflink-capable work filesystem and a successful configuration parse. If either fails, stop and record the incompatibility rather than claiming the Docker profile fixes it. Keep any future source patch separately reviewed from clinical deployment changes.

The site configuration also used `stageInMode = 'copy'` for `DCM2BIDS_POSTPROC`, whose script moves/edits staged files. This is a configuration override and avoids altering upstream files through staged links. Recheck available disk space when using copies.

### Image preparation

Provide locally built or approved images with explicit versions/digests. Example names below are placeholders, not published images:

```groovy
// docker-site.config: replace all image names with prepared local images.
docker.enabled = true
apptainer.enabled = false
executor.queueSize = 8
executor.cpus = 32
executor.memory = '200 GB'
process {
    executor = 'local'
    withName: 'DCM2BIDS|DCM2BIDS_CONFIG|DCM2BIDS_POSTPROC|MERGE_BIDS_DATASET|BIDSIGNORE|BIDS_QC_GATE' {
        ext.container = 'site/neuromriprep-conversion:PINNED'
        cpus = 1
        memory = '2 GB'
    }
    withName: 'DCM2BIDS' {
        cpus = 16
        memory = '32 GB'
    }
    withName: 'DCM2BIDS_POSTPROC' { stageInMode = 'copy' }
    withName: 'BIDS_VALIDATOR' {
        ext.container = 'site/neuromriprep-validator:PINNED'
        cpus = 2
        memory = '6 GB'
    }
    withName: 'PYDEFACE' {
        ext.container = 'site/neuromriprep-pydeface:PINNED'
        cpus = 4
        memory = '16 GB'
        maxForks = 8
    }
}
```

This example assumes a dedicated 32-CPU, adequately provisioned Linux host. Reduce limits on shared or smaller systems. Configure Docker user IDs and read-only input mounts to match site permissions; smoke-test with the actual task user. If applying per-container CPU/memory limits, align them with Nextflow allocations rather than setting a lower global cap that silently constrains every task.

The tested image preparation addressed these details:

- Conversion/helper images needed Bash, Python, jq, GNU coreutils and process-monitoring utilities in addition to dcm2bids/dcm2niix; installed software had to be readable by the task UID.
- The validator image needed Bash and a working `bids-validator` command, not only an image entrypoint. Check its log format against the pipeline's gate parser.
- PyDeface needed its Python/FSL environment exported for a non-interactive shell. An interactive activation hook or an entrypoint that always runs the application can break Nextflow's shell wrapper. Record actual package versions; the tested PyDeface image reported a development version, which should not silently become a clinical standard.
- Pin base images by digest and retain build recipes. Rebuilding an image with unpinned package-manager dependencies is not guaranteed to reproduce the same image. Archive the built image identity and, where permitted, the image itself.

A successful `--help` is only a smoke test. Run a small end-to-end input through conversion, validation and defacing before scaling up.

### Explicit stage settings

Use unquoted JSON booleans (or YAML booleans) in a parameter file. Add study-specific input, outdir, conversion-config and allowlist paths to this example:

```json
{
  "mode": "production",
  "stop_bidsval": false,
  "skip_mriqc": true,
  "stop_mriqc": true,
  "skip_fmriprep": true,
  "stop_fmriprep": false,
  "deface_tool": "pydeface",
  "enforce_bidsqc_gate": true
}
```

```bash
nextflow -c docker-site.config config . -profile docker -flat > resolved.config.txt
nextflow -log run.log run main.nf -profile docker \
  -c docker-site.config -params-file params.json \
  -work-dir /data/study/work/run01 \
  -with-report /data/study/reports/run01/report.html \
  -with-trace /data/study/reports/run01/trace.txt \
  -with-timeline /data/study/reports/run01/timeline.html
```

Create the report directory first. Inspect startup messages: both skip decisions should be explicit and the BIDS gate should be enforced. A deployment encountered CLI Boolean overrides behaving differently from the intended parameter-file settings; removing redundant CLI overrides and verifying typed JSON values resolved that case. Do not generalize this observation to all Nextflow versions. Check the actual startup behavior, and remember CLI parameters take precedence over parameter files. `nextflow config` checks configuration resolution, not task execution or the complete study parameter file.

## Transfers, supervision and resuming

Inventory complete acquisitions before upload. Do not select by series number alone across different protocols. Record included and excluded series, reasons, participant/session aliases and checksums. A pipeline smoke-test subset and the complete scientific dataset are different artifacts; truncating a functional series changes its scientific meaning.

Transfer only needed inputs, resume interrupted transfers, then verify every selected file against a source SHA-256 manifest. File count alone is insufficient. Launch only after verification succeeds. Keep input data immutable. Store separate config, input, work, results and reports directories for each study/run.

Run long jobs through the approved scheduler or a persistent, logged launcher. SSH disconnection should not terminate the workflow. For a workstation, prevent sleep while the job runs if permitted. Keep Nextflow's `.nextflow` cache and work directory. With multiple participant-specific launches, use `-resume <run-name-or-session-id>` for the correct earlier session rather than relying on whichever run happened last. Changes to parameters or task definitions may invalidate caches: `-resume` is not a guarantee that conversion will be skipped.

Monitor trace rows, published outputs and the workflow log. A container exiting with code zero does not establish that Nextflow recorded and published its output. Conversely, an empty downstream channel after a failed QC gate may allow Nextflow to finish without defacing. Require the expected derivative count and successful gate status (or a documented exception), not just a zero launcher exit code.

## QC exceptions and scientific interpretation

Keep `enforce_bidsqc_gate=true` by default. Investigate naming/metadata failures first. If an authorized study owner explicitly permits internal processing despite known findings, `enforce_bidsqc_gate=false` reports the gate result but lets downstream processing proceed. Archive the authorization, exact findings, rationale and restricted-use status. Do not relabel a failed gate as passed or add broad ignore rules to hide errors. This setting does not repair BIDS compliance or approve publication.

Production defacing selects anatomical NIfTI files under `anat/`. It does not automatically deface BOLD, SBRef or field-map files. FLASH echoes are repeated echo measurements within an acquisition; they are not independent biological samples. A broader anatomical selection also broadens the need to inspect contrast-specific defacing performance.

Check facial removal and unintended tissue removal for every applicable image. The current PyDeface output declaration publishes defaced images, not reusable masks/transforms. Saving and transferring a mask to another acquisition is a separate workflow requiring correct registration and geometry checks. Do not infer brain preservation from successful execution or from a few illustrative slices.

Report timings with hardware, architecture, resource allocations, observed utilization, concurrency, container identities and whether upload/setup time was excluded. Parallel images can improve throughput even when individual registration tasks use approximately one CPU core. Speedups from native Linux versus emulated Docker Desktop are not controlled hardware-only comparisons.

For external release, separately review consent/authorization, identifiers in DICOM and JSON metadata, filenames, dates, logs and original images. A reproducible internal test package is not automatically a publishable patient dataset.
