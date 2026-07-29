/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { FMRIPREP } from '../../../modules/local/fmriprep'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN FMRIPREP SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow FMRIPREP_PARTICIPANTS {

    take:
    ch_input         // channel: [ val(meta), path(dicom_dir) ]
    ch_bids_dataset  // channel: path(bids_dataset) or value(path)

    main:

    // per-subject/session meta channel
    ch_fmriprep_meta = ch_input
        .map { meta, ignored -> meta }
        .map { meta -> meta + [ id: "sub-${meta.subject}" ] }

    // optional VPN file restriction
    if( params.fmriprep_vpn_file ) {
        def vpn_set = file(params.fmriprep_vpn_file)
            .text
            .readLines()
            .collect { it.replace('\r','').trim() }
            .findAll { it }
            .collect { it.replaceFirst(/^sub-/, '') }
            .toSet()

        ch_fmriprep_meta = ch_fmriprep_meta.filter { meta ->
            vpn_set.contains(meta.subject.toString().replaceFirst(/^sub-/, ''))
        }
    }

    // resolve BIDS filter file
    def bf      = params.fmriprep_bids_filter ? params.fmriprep_bids_filter.toString() : null
    def bf_path = null

    if( bf ) {
        if( bf == 'ses01' ) {
            bf_path = '/nic/sw/IRTG/scripts/bids-filter-file/filter_ses01.json'
        } else if( bf == 'ses02' ) {
            bf_path = '/nic/sw/IRTG/scripts/bids-filter-file/filter_ses02.json'
        } else {
            bf_path = bf
        }
    }

    def ch_bids_filter = bf_path \
        ? Channel.value(file(bf_path)) \
        : Channel.value(file("${projectDir}/assets/empty_bids_filter.json"))

    // FreeSurfer license from input/ default
    def ch_fs_license = Channel.value(file(params.fmriprep_fs_license))

    // structure inputs for module
    ch_fmriprep_in = ch_fmriprep_meta
        .combine(ch_bids_dataset)
        .combine(ch_fs_license)
        .combine(ch_bids_filter)
        .map { meta, ds, lic, filt -> [ meta, ds, lic, filt ] }

    // run module
    FMRIPREP(ch_fmriprep_in)

    // reshape publish output
    ch_fmriprep_pub = FMRIPREP.out.fmriprep_publish.flatten()
    ch_fmriprep_version = FMRIPREP.out.versions

    ch_fmriprep_publish = ch_fmriprep_pub.map { p ->
        def rel = p.toString().replaceFirst(/^.*[\\\/]fmriprep_out_[^\/]+\//, '')
        return [ file: p, rel: rel ]
    }

    emit:
    fmriprep_publish = ch_fmriprep_publish
    fmriprep_versions = ch_fmriprep_version
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/