include { MRIQC_PARTICIPANT } from '../../../modules/local/mriqcparticipant/'


def readVpnLabels(vpnPath) {
    if (!vpnPath) {
        return [] as List
    }

    def f = file(vpnPath)

    if (!f.exists()) {
        throw new IllegalArgumentException("VPN file not found: ${vpnPath}")
    }

    return f.readLines()
        .collect { line -> line.replace('\r', '').trim() }
        .findAll { line -> line && !line.startsWith('#') }
        .collectMany { line -> line.tokenize() }
        .collect { label -> label.replaceFirst(/^sub-/, '') }
        .unique()
}


workflow MRIQC_PARTICIPANTS {

    take:
    ch_dataset_in
    vpn_file

    main:

    participant_labels = readVpnLabels(vpn_file)

    /*
     * One dataset-level MRIQC participant call.
     * ch_dataset_in emits: tuple(meta, bids_dataset)
     */
    ch_mriqc_run = ch_dataset_in.map { meta, bids_dataset ->
        tuple(meta, bids_dataset, participant_labels)
    }

    run = MRIQC_PARTICIPANT(ch_mriqc_run)

    /*
     * Reattach the BIDS dataset path to the MRIQC output directory
     * so MRIQC_GROUP can stage both.
     */
    ch_dataset_keyed = ch_dataset_in.map { meta, bids_dataset ->
        tuple(meta.id ?: meta.project ?: 'dataset', meta, bids_dataset)
    }

    ch_mriqc_keyed = run.mriqc_out.map { meta, mriqc_dir ->
        tuple(meta.id ?: meta.project ?: 'dataset', meta, mriqc_dir)
    }

    ch_group_in = ch_dataset_keyed
        .join(ch_mriqc_keyed)
        .map { key, meta, bids_dataset, meta2, mriqc_dir ->
            tuple(meta, bids_dataset, mriqc_dir)
        }

    emit:
    mriqc_out      = run.mriqc_out
    mriqc_out_pub  = run.mriqc_publish
    mriqc_group_in = ch_group_in
    mriqc_log      = run.mriqc_log
    versions       = run.versions
}