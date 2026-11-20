# Deployment examples

These examples are templates and build recipes, not study data or a turnkey site configuration. Replace placeholder paths, confirm runtime and storage settings with local IT, and review the image inventory before use.

- [`irtg-clinical/`](irtg-clinical/): sample `site.config` and `params.yaml` using the institutional IRTG SIF paths.
- [`docker-solidfox/`](docker-solidfox/): container-to-module inventory, tested image versions, image IDs, parameter overrides and Dockerfiles from the Solidfox integration run.

The Docker inventory distinguishes the modules that completed in the run from fMRIPrep and optional methods that were not exercised. The Solidfox-local image tags are not public registry images.
