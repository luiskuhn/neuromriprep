# Deployment: clinical SIF installations and portable Docker sites

This guide complements [technical usage](usage.md) and the [production checkpoints](production_workflow_guide.md). It documents deployment choices; it does not change the clinical workflow or promise that every module is runtime-independent.

## Clinical deployment is the primary operating context

neuromriprep was developed for [IRTG-2804](https://irtg2804.de/), an international research training group studying women's mental health across reproductive transitions. In its University Hospital clinical deployment, processing must remain within the approved clinical network. Internet and data access are restricted; container images are supplied as IT-approved local `.sif` files. Do not replace these images with public registry downloads on clinical systems or move patient data outside that environment to solve an installation problem.

Apptainer/Singularity is the approved runtime in this setting. Use the explicit `-profile irtg`; the generic `-profile apptainer` remains as a backward-compatible alias. The IRTG profile enables Apptainer with automatic mounts and disables the competing container runtimes. Its adoption reflects institutional security and operational policy; it is not a blanket claim that one runtime makes patient data secure. Follow local IT requirements for runtime version, image provenance, privileges, bind mounts, storage and network access. Container execution is delegated to Nextflow's process `container` directive; fMRIPrep additionally configures a read-only TemplateFlow bind using the selected runtime's syntax.

An international collaborating site may permit Docker. That is a separate deployment decision, not permission to export clinical data. Establish the receiving site's authorization, data-transfer agreement and approved storage before transferring inputs. Defacing alone does not authorize public redistribution or remove identifying metadata.

## What can actually be configured?

| Stage | Central image parameter | Current deployment note |
| --- | --- | --- |
| Conversion and dataset assembly | `dcm2bids_config_container`, `dcm2bids_container`, `dcm2bids_output_patch_container`, `dcm2bids_postproc_container`, `merge_bids_dataset_container` | Defaults point to the IRTG SIF set; external sites must supply compatible images for the enabled processes. |
| Validation and QC gate | `bidsignore_container`, `bidsvalidator_container`, `bids_qc_gate_container` | The validator image must provide Bash and `bids-validator`; the QC gate image must provide the Python runtime expected by its script. |
| MRIQC | `mriqc_participant_container`, `mriqc_group_container` | Both stages use Nextflow-managed containers. The Docker profile provides the MRIQC image defaults; both stages completed in a full single-subset Solidfox integration run. |
| fMRIPrep | `fmriprep_container` | Docker and Apptainer are supported at the process launch level. fMRIPrep still requires a FreeSurfer license and a readable TemplateFlow cache; a Docker fMRIPrep smoke test has not been run. |
| Defacing and benchmark QC | `pydeface_container`, `mri_deface_container`, `fsl_deface_container`, `afni_refacer_container`, `deepdefacer_container`, `deface_qc_render_container`, `deface_metrics_container`, `deface_detector_container`, `merge_benchmark_container` | Defaults preserve the established SIF setup; DeepDefacer retains a legacy site-specific image path. An alternate site must supply images containing each module's executable and dependencies. |

Container selection is centralized in `conf/modules.config`, while parameter defaults are declared in `nextflow.config` and documented in `nextflow_schema.json`. Use the named parameters in a `-params-file` to substitute site images. The Docker profile includes defaults only for MRIQC and fMRIPrep; other Docker images remain a site responsibility. See [container parameters and examples](usage.md#5-configure-images-resources-and-reference-data).

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

## Step-by-step IRTG clinical run

These are operator steps for the clinical compute environment. They must be adapted to local scheduler, storage and security policy. Test the site-specific steps with the radiology/clinical IT team; this guide has not been executed in that environment.

1. **Prepare the approved software environment.** Obtain the approved pipeline checkout/revision, Nextflow and Java installation, Apptainer module, and all required SIF files through the hospital's normal software provisioning process. Keep the source, work, configuration, reports and results on approved storage. Do not pull containers or expose patient inputs to a public registry.
2. **Check the execution host.** From the repository root, record the revision and check `nextflow -version`, `java -version`, and `apptainer --version`. Confirm that the scheduler allocation, scratch quota, memory and CPU limits match the `site.config`. Verify that required images are readable on compute nodes and record `sha256sum` values and IT provenance.
3. **Prepare local run configuration.** Start from [`assets/examples/irtg-clinical/site.config`](../assets/examples/irtg-clinical/site.config) and [`assets/examples/irtg-clinical/params.yaml`](../assets/examples/irtg-clinical/params.yaml). Replace the example input, output, DCM2BIDS, allowlist and BIDS-filter paths with approved site paths; confirm that all execution nodes can read them. The parameter example lists the default IRTG SIF paths explicitly. Use typed YAML booleans. Keep site paths and study metadata out of public source control.
4. **Resolve and inspect configuration before submitting.** Run `nextflow -c site.config config . -profile irtg -flat` and review the resolved file for the expected Apptainer runtime, local SIF paths, and resource overrides. Then inspect `params.yaml` directly to confirm input/output locations, enabled stages and typed Boolean settings. The config subcommand does not load a `-params-file`; the run's startup messages and execution trace provide the final check. These checks do not prove that images, references or input data are valid.
5. **Run conversion and validation first.** Set `skip_mriqc: true`, `skip_fmriprep: true` and `enforce_bidsqc_gate: true` in the parameter file, then launch:

   ```bash
   nextflow run . -profile irtg -c site.config -params-file params.yaml \
     -work-dir /approved/scratch/neuromriprep-work \
     --stop_bidsval true --stop_mriqc true --stop_fmriprep true \
     -with-report /approved/reports/nextflow-report.html \
     -with-trace /approved/reports/nextflow-trace.txt \
     -with-timeline /approved/reports/nextflow-timeline.html
   ```

   Submit through the site-approved scheduler or persistent launcher and retain the session log. Review the BIDS conversion, parsed participant/session labels, metadata, `dataset_validation_log.txt` and `bids_qc_summary.txt`. Continue only after the gate reports `check_passed: True` or an authorized, documented exception.
6. **Run only the authorized downstream stages.** For a defacing run without MRIQC or fMRIPrep, retain `skip_mriqc: true` and `skip_fmriprep: true`, review the gate, then resume the same session and work directory:

   ```bash
   nextflow run . -profile irtg -c site.config -params-file params.yaml \
     -work-dir /approved/scratch/neuromriprep-work -resume \
     --stop_bidsval false --stop_mriqc false --stop_fmriprep false \
     --deface_tool pydeface
   ```

   This allows the enabled defacing branch while keeping fMRIPrep ineligible. If MRIQC is approved and configured, set `skip_mriqc: false` and use the MRIQC review checkpoint in [the production workflow guide](production_workflow_guide.md). fMRIPrep requires a valid FreeSurfer license and complete TemplateFlow resources; do not enable it until the site has provisioned these and the study has authorized its use.
7. **Review outputs and preserve provenance.** Check the exit status, Nextflow session log, trace, reports, BIDS gate, expected derivative counts, and visual defacing QC. Preserve the exact revision, parameter and site configurations, container checksums, scheduler/resource settings, and work/cache directories until the run is reviewed. Defaced anatomical outputs do not make original data, sidecars, logs or other modalities anonymous.

## Portable Docker route: site-specific image configuration

**Solidfox** is the name used here for the remote Linux Docker host used for the integration test. It is a native x86-64 machine with 32 CPUs and approximately 252 GiB RAM, running Docker 29.0.2; Nextflow used its local executor. This host is separate from the University Hospital radiology/clinical compute environment and its restricted-network deployment. Results on Solidfox therefore provide Docker-host evidence only, not validation of the clinical Apptainer environment.

Here, “portable” means that a site can select compatible images through pipeline parameters. The Docker profile is **not plug-and-play outside Solidfox**: it supplies default Docker references only for MRIQC and fMRIPrep, while the other process parameters still default to IRTG `.sif` paths. Before running Docker at another site, override every image parameter used by the selected workflow with a Docker image containing the expected executables, scripts, libraries and templates. Verify image architecture, availability, UID/GID and bind-mount behavior on that host. fMRIPrep additionally needs a valid FreeSurfer license and a populated TemplateFlow cache; it was not part of the completed Solidfox run. The successful one-subset test demonstrates this configuration on one Linux host, not universal cross-site compatibility.

The [Solidfox Docker inventory](../assets/examples/docker-solidfox/README.md) lists the exact tested image tags, application versions, image IDs, module assignments and Dockerfile build recipes. It marks the configured-but-uninvoked process and the untested optional modules separately.

The production workflow completed a Docker integration run on a native Linux x86-64 Solidfox host (32 CPUs, approximately 252 GiB RAM, Docker 29.0.2, Java 25.0.3 and Nextflow 26.04.6). The run used one restricted internal participant/session test subset; no input images or participant identifiers are included in this repository. Conversion, dataset assembly, validation, the enforced BIDS QC gate, MRIQC participant/group processing and eight PyDeface anatomical-image tasks completed. The gate passed with zero errors; five warnings were all handled by the configured allowlist. MRIQC participant processing took about 35 minutes, group processing about 3 seconds, and individual PyDeface tasks took about 4.5–8 minutes while running concurrently. The resumed pipeline run took about 35 minutes; the first attempt and recovery extended total elapsed time to roughly 43 minutes. fMRIPrep was deliberately skipped because no FreeSurfer license was available. This is a single-subset integration check, not a full-cohort validation or a controlled performance benchmark.

Clinical parameter and site-config templates are in [`assets/examples/irtg-clinical/`](../assets/examples/irtg-clinical/). They explicitly show the default `/nic/sw/IRTG/sif/` image locations. Replace all `/approved/...` study paths, prepare a subject allowlist containing one BIDS subject label per line, and create the referenced `bids_filter.json` (use `{}` for no BIDS filtering). The sample begins with stop flags enabled for the conversion/validation review checkpoint. It leaves MRIQC and fMRIPrep eligible for subsequent stages; if fMRIPrep is not authorized or its license/reference data are not available, set `skip_fmriprep: true` in the private parameter file before opening downstream stop gates.

The first attempt exposed that Solidfox's ext4 work volume does not support mandatory reflink cloning. Dataset assembly now uses `cp --reflink=auto`, retaining copy-on-write where available and falling back to ordinary copies; the resumed run completed on ext4. Docker Desktop on Apple silicon was also exercised with amd64 emulation, but its performance is not representative of native Linux.

### Preconditions before claiming an unchanged-source deployment

Dataset assembly uses `cp --reflink=auto`: it uses copy-on-write where supported and falls back to ordinary copies on filesystems such as Solidfox ext4. The fallback needs more scratch space and may take longer. The completed Solidfox test exercised the standardized PR source; it does not establish compatibility with every filesystem or deployment. Record the exact workflow revision used.

The site configuration also used `stageInMode = 'copy'` for `DCM2BIDS_POSTPROC`, whose script moves/edits staged files. This is a configuration override and avoids altering upstream files through staged links. Recheck available disk space when using copies.

### Image preparation

Provide locally built or approved images with explicit versions/digests. Image names below are placeholders, not published images. Put image overrides in `docker-images.json`; do not encode images in `process.ext.container` blocks:

```json
{
  "dcm2bids_config_container": "site/neuromriprep-helper:PINNED",
  "dcm2bids_container": "site/neuromriprep-conversion:PINNED",
  "dcm2bids_output_patch_container": "site/neuromriprep-conversion:PINNED",
  "dcm2bids_postproc_container": "site/neuromriprep-helper:PINNED",
  "merge_bids_dataset_container": "site/neuromriprep-helper:PINNED",
  "bidsignore_container": "site/neuromriprep-helper:PINNED",
  "bidsvalidator_container": "site/neuromriprep-validator:PINNED",
  "bids_qc_gate_container": "site/neuromriprep-python:PINNED",
  "pydeface_container": "site/neuromriprep-pydeface:PINNED"
}
```

For this subset, use a separate `docker-site.config` for resource and staging settings:

```groovy
docker.enabled = true
apptainer.enabled = false
executor.queueSize = 8
executor.cpus = 32
executor.memory = '200 GB'
process {
    withName: 'DCM2BIDS|DCM2BIDS_CONFIG|DCM2BIDS_POSTPROC|MERGE_BIDS_DATASET|BIDSIGNORE|BIDS_QC_GATE' {
        cpus = 1
        memory = '2 GB'
    }
    withName: 'DCM2BIDS' {
        cpus = 16
        memory = '32 GB'
    }
    withName: 'DCM2BIDS_POSTPROC' { stageInMode = 'copy' }
    withName: 'BIDS_VALIDATOR' {
        cpus = 2
        memory = '6 GB'
    }
    withName: 'PYDEFACE' {
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
  -c docker-site.config -params-file docker-images.json \
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
