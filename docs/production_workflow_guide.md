# neuromriprep: Production Workflow User Guide

Welcome! This guide is designed to help you run the **neuromriprep** pipeline on your MRI data. We’ve kept the language simple so that you can focus on your research without getting bogged down in technical details.

---

## What is neuromriprep?

**neuromriprep** is a "pipeline"—a series of automated steps—that takes your raw brain scans (DICOM files) and prepares them for scientific analysis. It organizes your data, checks for quality issues, cleans the images (preprocessing), and removes facial features to protect participant privacy (defacing).

---

## 1. Before You Start

To run this pipeline, you need two things installed on your computer or server:
1.  **Nextflow**: The engine that runs the pipeline.
2.  **Docker** or **Singularity/Apptainer**: Tools that handle all the complex scientific software automatically so you don't have to install them yourself.

> [!TIP]
> If you are working on a university cluster (like the NIC), these are usually already set up for you!

---

## 2. Organizing Your Data

The pipeline identifies subjects based on folder names in your data directory.

### Subject Folder Format:
`IRTGXX`
-   **XX**: The Subject ID (e.g., `01`, `02`, `10`).

**Example**: A folder named `IRTG05` tells the pipeline this is **Subject 05**.

---

## 3. The Samplesheet (List of Data)

You must provide a CSV file mapping project IDs to their data locations.

### Example `samplesheet.csv`:
```csv
project,dicom_dir
01,/path/to/your/data/IRTG01
01,/path/to/your/data/IRTG02
```

-   **project**: Usually a two-digit code for your project (e.g., `01`).
-   **dicom_dir**: The **absolute path** (full address) to the folder containing the raw scans.

> [!IMPORTANT]
> ### 🐍 Python Helper Script
> There is a Python script being developed to help you create this file automatically. 
> 
> *TODO: User to add details here once the script is available in the repository.*

---

## 4. Step 3: Running the Pipeline (The "Magic Command")

To run the full pipeline with all default cleaning and privacy steps:

```bash
nextflow run nf-core/neuromriprep \
    -profile <docker/singularity/apptainer> \
    --input ./samplesheet.csv \
    --outdir ./results \
    --run_complete
```

---

## 5. Deep Dive: All Pipeline Parameters

Below is an exhaustive list of every parameter you can set.

### 5.1. Required Parameters
| Parameter | Description |
| :--- | :--- |
| `--input` | Path to your `samplesheet.csv`. |
| `--outdir` | Main directory for results. |

### 5.2. Workflow Toggles (Step Control)
These flags control which parts of the pipeline run.

| Parameter | What it does |
| :--- | :--- |
| `--run_complete` | Shortcut to run the entire pipeline (Organize -> Check -> QC -> Clean -> Deface). |
| `--run_dcm2bids` | Specifically run the DICOM to BIDS conversion. |
| `--run_bidsvalidator` | Specifically run the BIDS format check. |
| `--run_mriqc` | Specifically run the MRIQC quality control. |
| `--run_fmriprep` | Specifically run the fMRIPrep image cleaning. |
| `--run_pydeface` | Specifically run the Defacing privacy step. |
| `--skip_mriqc` | Skip MRIQC even if `--run_complete` is on. |
| `--skip_fmriprep` | Skip fMRIPrep even if `--run_complete` is on. |

### 5.3. Stopping Points (For Manual Review)
The pipeline can pause at specific stages to allow you to check the data before moving to heavy processing.

| Parameter | When it stops |
| :--- | :--- |
| `--stop_bidsval` | Stops after BIDS validation. Defaults to `true`. Set to `false` to continue to downstream steps. |
| `--stop_mriqc` | Stops after MRIQC reports are generated. Defaults to `true`. |
| `--stop_fmriprep` | Stops after fMRIPrep cleaning is done. Defaults to `true`. |

### 5.4. Filtering Subjects (VPN Files)
You can limit processing to a subset of subjects by providing a text file (VPN file) containing a list of subject IDs (one per line, e.g., `IRTG01`).

| Parameter | Context |
| :--- | :--- |
| `--mriqc_vpn_file` | Only run MRIQC for subjects in this list. |
| `--fmriprep_vpn_file` | Only run fMRIPrep for subjects in this list. |
| `--pydeface_vpn_file` | Only run Defacing for subjects in this list. |

### 5.5. Tool-Specific Parameters

#### **DCM2BIDS (Data Organization)**
-   `--dcm2bids_config`: Path to your custom conversion rules (JSON).
-   `--force_dcm2bids`: Re-run conversion even if files already exist.
-   `--outdir_copy`: If set, copies DICOMs to this folder before processing.
-   `--search`, `--include`, `--exclude`: Substrings to filter DICOM folders during copying.

#### **fMRIPrep (Image Cleaning)**
-   `--fmriprep_fs_license`: **REQUIRED** path to your FreeSurfer license file.
-   `--fmriprep_bids_filter`: Use `ses01` or `ses02` to use built-in filters, or provide a path to your own filter JSON.
-   `--fmriprep_brainmask_dir`: Custom directory for brain masks.

#### **Defacing (Privacy)**
-   `--deface_tool`: Choose your tool: `mri_deface` (default), `pydeface`, `fsl_deface`, `afni_refacer`, `deepdefacer`.
-   `--nondefaced_detector_model_path`: Path to the weights for the defacing check model.

#### **mri_deface (Advanced Tuning)**
-   `--mri_deface_brain_template`: Path to brain template file.
-   `--mri_deface_face_template`: Path to face template file.
-   `--mri_deface_cpus`: Number of CPUs (default: 8).
-   `--mri_deface_mem`: Memory limit (default: 8 GB).
-   `--mri_deface_time`: Time limit (default: 2h).

### 5.6. Generic & Reporting
-   `--email`: Address for run summary.
-   `--email_on_fail`: Only email if the pipeline crashes.
-   `--multiqc_title`: Custom title for the MultiQC report.
-   `--monochrome_logs`: Use black & white terminal output.
-   `--plaintext_email`: Send summary emails as plain text.
-   `--hook_url`: URL for Slack/Teams notifications (Incoming Webhook).
-   `--multiqc_methods_description`: Path to a custom YAML file for the MultiQC methods section.
-   `--validate_params`: Boolean (true/false) to enable parameter validation against the schema at runtime.

---

## 6. Tweaking Resources (CPU & Memory)

Scientists often need more power for specific steps. You can adjust this without changing the pipeline code.

### Option A: Direct Parameters (for mri_deface)
Use the parameters listed in section 4.5 (e.g., `--mri_deface_mem '16 GB'`).

### Option B: Custom Config File
Create a file named `my_resources.config`:

```groovy
process {
    withName: 'FMRIPREP' {
        memory = '100 GB'
        cpus = 32
    }
}
```

Then run the pipeline with: `-c my_resources.config`.

---

## 7. Important Files in `assets/`

The pipeline uses several default files located in the `assets/` directory. You can override these using parameters:

-   `assets/scripts/bids_gate.py`: Logic for the QC gate.
-   `assets/input_pipeline/bidsval_allowlist.txt`: List of BIDS warnings to ignore.
-   `assets/dcm2bids_config_IRTG.json`: Default organization rules.

---

## 8. Understanding Results

-   `results/BIDS/`: Your standardized data.
-   `results/multiqc/`: Combined quality reports.
-   `results/derivatives/fmriprep/`: Cleaned images.
-   `results/derivatives/mriqc/`: Quality metrics.
-   `results/pipeline_info/`: Technical logs and execution reports.

---
*Documentation Version: 2.0 (Exhaustive)*
