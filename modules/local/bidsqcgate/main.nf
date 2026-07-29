process BIDS_QC_GATE {

  tag "bids-qc"

  label 'process_single'

  stageInMode 'copy'


  container { task.ext.container ?: '/nic/sw/IRTG/sif/python_3.11.14-trixie.sif' }

  input:
  tuple val(meta), path(bids_log), path(gate_py), path(warnings_ok), path(helpers)

  output:
  path("bids_qc_summary.txt"), emit: summary
  path("bids_qc_report.json"), emit: report
  tuple val(meta), path("check_passed.txt")   , emit: passed
  path "versions.yml"                         , emit: versions


script:
  def extra_args = task.ext.args ?: ''

  def helpers_arg = ''
  if( helpers instanceof List ) {
    if( helpers ) helpers_arg = "--helpers ${helpers[0]}"
  } else if( helpers ) {
    helpers_arg = "--helpers ${helpers}"
  }

  """
  set -euo pipefail

  python3 ${gate_py} \
    --log ${bids_log} \
    --allow-warnings ${warnings_ok} \
    ${helpers_arg} \
    --summary-out bids_qc_summary.txt \
    --json-out bids_qc_report.json \
    ${extra_args}

  python3 - <<'PY' > check_passed.txt
  import json
  with open("bids_qc_report.json") as f:
      print(str(json.load(f)["check_passed"]).lower())
  PY


  cat <<-END_VERSIONS > versions.yml
  "${task.process}":
    python: "\$(python3 --version 2>&1 | awk '{print \$2}')"
  END_VERSIONS
  """
}