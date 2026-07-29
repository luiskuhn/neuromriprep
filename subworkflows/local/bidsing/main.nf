/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { DCM2BIDS              } from '../../../modules/local/dcm2bids'
include { DCM2BIDS_CONFIG       } from '../../../modules/local/dcm2bidsconfig'
include { DCM2BIDS_OUTPUT_PATCH } from '../../../modules/local/dcm2bidsoutputpatch'
include { DCM2BIDS_POSTPROC     } from '../../../modules/local/dcm2bidspostprocess'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW: BIDSING
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow BIDSING {

    take:
    ch_input    // channel: [ val(meta), path(dicom_dir) ]
    ch_config   // channel: path(config_file)
    ch_force    // value channel: bool

    main:

    /*
     * Step 1: create modified config
     */
    ch_cfg_in = ch_input
        .combine(ch_config)
        .map { meta, dicom_dir, config_file ->
            tuple(meta, config_file)
        }

    DCM2BIDS_CONFIG(ch_cfg_in)

    ch_modified_cfg = DCM2BIDS_CONFIG.out.config



    /*
     * Step 2: run dcm2bids
     * join output shape here is: [meta, dicom_dir, modified_config]
     */
    ch_run_in = ch_input
        .join(ch_modified_cfg)
        .map { meta, dicom_dir, modified_config ->
            tuple(meta, dicom_dir, modified_config)
        }

    DCM2BIDS(
        ch_run_in,
        ch_force
    )

    ch_bids_raw = DCM2BIDS.out.bids_output

    /*
     * Step 3.1: patch output for selective patients
     */
    
    if (params.dcm2bids_output_patch_vpn) {

    ch_b0field_patch_vpn = Channel.value(
        file(params.dcm2bids_output_patch_vpn, checkIfExists: true)
    )

    DCM2BIDS_OUTPUT_PATCH(
        ch_bids_raw,
        ch_b0field_patch_vpn
    )

    ch_bids_for_postproc = DCM2BIDS_OUTPUT_PATCH.out.bids_output

    } else {

        ch_bids_for_postproc = ch_bids_raw
    }

    /*
     * Step 3.2: postprocess BIDS output
     */
    
    DCM2BIDS_POSTPROC(ch_bids_for_postproc)

    emit:
    bids_raw         = ch_bids_raw
    bids_sub         = DCM2BIDS_POSTPROC.out.bids_sub
    dwi_adc_sub      = DCM2BIDS_POSTPROC.out.dwi_adc_sub
    dcm2bids_log     = DCM2BIDS.out.log
    versions         = DCM2BIDS.out.versions
    modified_config  = ch_modified_cfg
}