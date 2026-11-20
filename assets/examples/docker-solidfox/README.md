# Docker images used in the Solidfox integration run

“Solidfox” here refers to the remote native Linux x86-64 Docker host used for integration testing (32 CPUs, approximately 252 GiB RAM, Docker 29.0.2, with Nextflow's local executor), not the hospital's clinical compute environment.

The Docker profile supplies upstream MRIQC and fMRIPrep image tags only. The remaining production modules keep their IRTG SIF defaults until overridden through the corresponding `*_container` parameter. This inventory records the Docker image mapping from the completed one-subset Solidfox run; it is not a general Docker profile default set.

## Module-to-image mapping

| Process/module | Image used or selected | Version/provenance | Dockerfile and test status |
| --- | --- | --- | --- |
| `DCM2BIDS_CONFIG`, `DCM2BIDS`, `DCM2BIDS_POSTPROC`, `MERGE_BIDS_DATASET`, `BIDSIGNORE`, `BIDS_QC_GATE` | `hauser/dcm2bids:3.2.0-solidfox-test-02` | dcm2bids 3.2.0 base; local image ID `sha256:772cd7143d13a57fd9f8a544a2ce64da9c0a8fedf0e16f1ce97e48966f905171` | [Dockerfile.dcm2bids](Dockerfile.dcm2bids); these modules ran successfully. |
| `DCM2BIDS_OUTPUT_PATCH` | Same helper image above | Same build/version | Configured to use the helper image, but this process was not invoked by the test subset. |
| `BIDS_VALIDATOR` | `hauser/bids-validator:2.5.6-solidfox-test-02` | bids-validator 2.5.6; local image ID `sha256:513f0d14a078e1c6dec2600e8a1308ce0b0668f9d676bb688c9968215b142c27` | [Dockerfile.validator](Dockerfile.validator); validation completed successfully. |
| `MRIQC_PARTICIPANT`, `MRIQC_GROUP` | `nipreps/mriqc:25.0.0rc0` | MRIQC 25.0.0rc0; registry digest `sha256:90245f22c7d00cde771366d32b5c2342e546816a683c12804a9bb8c41db39f85` | Upstream image; no local Dockerfile. Both stages completed successfully. |
| `PYDEFACE` | `hauser/pydeface:solidfox-test-02` | PyDeface 2.1.1.dev0; local image ID `sha256:db5936cb77908909dc50b9646b53a03360a1654344c9c541132c2bc82f01f989` | [Dockerfile.pydeface](Dockerfile.pydeface); all eight tasks completed successfully. |
| `FMRIPREP` | `nipreps/fmriprep:24.1.1` | Docker-profile default tag; resolved image digest not recorded | Not run: no FreeSurfer license was available. Requires a valid license and TemplateFlow cache. |
| `MRI_DEFACE`, `FSL_DEFACE`, `AFNI_REFACER`, `DEEPDEFACER`, `DEFACE_QC_RENDER`, `DEFACE_METRICS`, `DEFACE_DETECTOR`, `MERGE_BENCHMARK` | No Docker image tested | These parameters still inherit their SIF defaults unless overridden. | Not part of the production run. Provide and verify compatible Docker images before enabling these processes. |

The Solidfox-local image IDs identify those exact built images; they are not pullable registry digests. The Dockerfile base images are digest-pinned, but package-manager dependencies in the build steps are not version-locked. Rebuilds may therefore differ. Before production use, retain the build logs, lock or pin mutable dependencies, publish images to an approved registry, and record the resulting registry digest.

## Build the three local test images

Run from the repository root on a connected, approved build host. The resulting `hauser/*` tags are local example names; retag them for your registry before use elsewhere.

```bash
docker build -f assets/examples/docker-solidfox/Dockerfile.dcm2bids \
  -t hauser/dcm2bids:3.2.0-solidfox-test-02 .
docker build -f assets/examples/docker-solidfox/Dockerfile.validator \
  -t hauser/bids-validator:2.5.6-solidfox-test-02 .
docker build -f assets/examples/docker-solidfox/Dockerfile.pydeface \
  -t hauser/pydeface:solidfox-test-02 .
```

The process-parameter overrides are listed in [container-params.yaml](container-params.yaml). They cover the tested production stages; they do not supply Docker images for optional benchmark or defacing-method modules.
