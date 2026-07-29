process MERGE_BENCHMARK {

    tag "merge_benchmark"

    cpus   { (params.merge_benchmark_cpus ?: 1) as Integer }
    memory {  params.merge_benchmark_mem  ?: '2 GB' }
    time   {  params.merge_benchmark_time ?: '1h' }

    input:
    path(metric_manifest)
    path(detector_manifest)
    path(merge_script)

    output:
    path("benchmark_per_subject_method.csv"), emit: per_subject_method_table
    path("benchmark_summary_by_method.csv"), emit: summary_table
    path("logs/*.log"), emit: logs

    shell:
    '''
    set -euo pipefail

    mkdir -p logs

    python3 "!{merge_script}" \
      --out-per-subject benchmark_per_subject_method.csv \
      --out-summary benchmark_summary_by_method.csv \
      --metric-manifest "!{metric_manifest}" \
      --detector-manifest "!{detector_manifest}" \
      1> >(tee -a logs/merge_benchmark_out.log) \
      2> >(tee -a logs/merge_benchmark_err.log >&2)
    '''
}