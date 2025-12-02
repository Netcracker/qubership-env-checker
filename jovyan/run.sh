#!/bin/bash

file_path=""
outs=()

#declare -A params
reports=("pdf")
overall_result=0
pdf_reporting_enabled=true
html_reporting_enabled=false
json_reporting_enabled=false
clear_out=true
print_usage(){
    echo -e "   \033[1mUsage:\033[0m bash run.sh [OPTIONS] [-PARAM_NAME=PARAM_VALUE] COMPOSITE_FILE_PATH|NOTEBOOK_FILE_PATH"
    echo -e "   \033[1mExecutes:\033[0m"
    echo -e "     - a single notebook with optional parameters"
    echo -e "     - a list of notebooks with parameters from a composite file"
    echo -e "   \033[1mExamples:\033[0m"
    echo -e "     bash run.sh /home/jovyan/tests/notebooks/test_notebook.ipynb                         \033[36m# single notebook (no reports)\033[0m"
    echo -e "     bash run.sh --namespace=my_ns /home/jovyan/tests/notebooks/test_notebook.ipynb       \033[36m# single with param\033[0m"
    echo -e "     bash run.sh --pdf=false --html=true /home/jovyan/tests/notebooks/test_notebook.ipynb \033[36m# disable PDF, enable HTML\033[0m"
    echo -e "     bash run.sh --html=true tests/CompositeUnitTestNotebook.ipynb                        \033[36m# composite notebook (runs all unit checks)\033[0m"
    echo -e "     bash run.sh tests/composite_test.yaml                                                \033[36m# composite YAML bulk run\033[0m"
    echo -e "   \033[1mParameters for a single notebook:\033[0m"
    echo -e "     pass as --param=value on the command line"
    echo -e "     e.g. --namespace=my_ns --app=env-checker"
    echo -e "   \033[1mOptions (o-optional, m-mandatory):\033[0m"
    echo -e "   \033[1m  -r 1m[s3|monitoring|pdf] (o)\033[0m  \033[36m# Upload results to corresponding services (comma-separated), e.g. -r s3,monitoring,pdf\033[0m"
    echo -e "   \033[1m  -y 1m (o)\033[0m                  \033[36m# Run YAML configuration provided inline (file path is ignored)\033[0m"
    echo -e "   \033[1m  -j 1m (o)\033[0m                  \033[36m# Run JSON configuration provided inline (file path is ignored)\033[0m"
    echo -e "   \033[1m  -e 1m (o)\033[0m                  \033[36m# Execute a Python script that outputs YAML, then run that YAML\033[0m"
    echo -e "   \033[1m  -o 1m (o)\033[0m                  \033[36m# Place outputs under './out/<subfolder>'\033[0m"
    echo -e "   \033[1m  --pdf=false 1m (o)\033[0m         \033[36m# Disable PDF report generation\033[0m"
    echo -e "   \033[1m  --html=true 1m (o)\033[0m         \033[36m# Enable HTML summary generation from scrapbook data\033[0m"
    echo -e "   \033[1mComposite YAML example:\033[0m"
    echo -e "     checks:"
    echo -e "       - path: /home/jovyan/tests/notebooks/test_notebook.ipynb"
    echo -e "         params:"
    echo -e "           namespace: my_namespace"
    echo -e "       - path: /home/jovyan/tests/CompositeUnitTestNotebook.ipynb"
    echo -e "         params:"
    echo -e "           report_name: CompositeUnitTestBulkNotebook"
    echo -e "   \033[1m Reports:\033[0m"
    echo -e "  \trunner converts results to pdf by default. Other reports you have to enable using -r flag."
    echo -e "  \tIn case of -r flag, the runner includes only reports mentioned in the list: "
    echo -e "  \tExample: "
    echo -e "          -r s3,pdf: report results to s3 and pdf"
    echo -e "          -r s3: report results to s3 only. Reporting to PDF is disabled here"
    echo -e "          -r '': disable all reports"
    echo -e ""
}

prepareOutput() {
    if [ "$clear_out" = false ]; then
        return
    fi

    if [ -d "/home/jovyan/out" ]; then
        find /home/jovyan/out -type d -empty -delete          # delete all empty catalogs in './out' folder
        find /home/jovyan/out -maxdepth 1 -type f -delete     # delete all files in './out' folder (except for non-empty subfolders)
        if [ -f /home/jovyan/shells/remove_out_catalogs.sh ]; then
            # shellcheck disable=SC1091
            # shellcheck source=/home/jovyan/shells/remove_out_catalogs.sh
            # deleting directories and subdirectories in the out folder for the last hour
            source /home/jovyan/shells/remove_out_catalogs.sh
        fi
        if [[ -n $output_subfolder ]]; then
            rm -rf "/home/jovyan/out/$output_subfolder"       # delete subfolder
        fi
    else
        mkdir -p /home/jovyan/out                               # recreate out folder
    fi
    mkdir -p "/home/jovyan/out/$output_subfolder"             # create subfolder if '-o' flag was filled
    composite_result_file_path="/home/jovyan/out/$output_subfolder/result.yaml"
    yq --null-input '{"checks": []}' > "$composite_result_file_path" # create result.yaml file with initial contents
}

# $1 - name and full path to composite .yaml file
runComposite() {
    # get composite file content without any comments
    composite_file_content=$(yq -oy '... comments=""' "$1")
    checks_amount=$(echo "$composite_file_content" | yq -oy e '.checks | length')

    for ((i=0;i<checks_amount;i++))
    do
        notebook_path=$(calculate_composite_notebook_path)
        params="$(echo "$composite_file_content" | yq -oy e ".checks.[$i] | select(.params != null) | .params")"
        out="$(echo "$composite_file_content" | yq -oy e ".checks.[$i] | select(.out != null) | .out")"
        runSingleNotebook "$notebook_path" "$params" "$out"
    done
}

calculate_composite_notebook_path() {
    notebook_path="$(echo "$composite_file_content" | yq -oy e ".checks.[$i] | select(.path != null) | .path")"
    echo "$notebook_path"
}

# $1 - executed notebook path
# $2 - overall binary notebook execution status
# $3 - initiator
# $4 - namespace
extract_notebook_execution_metrics() {
    report_name=$(basename -- "$1" | sed -nr 's/([a-zA-Z0-9_]+)_[0-9]+\.ipynb/\1/p' | awk '{print tolower($0)}')
    # try to extract 'metrics' scrap from executed notebook
    metrics=$(python -c "import nb_data_manipulation_utils as m; print(m.extract_metrics_from_nb_scraps('$1'))" 2>/dev/null || echo '{}')
    if [ "$metrics" != '{}' ] ; then
        # if such scrap was extracted, validate its content with json schema
        metrics_validation_res=$(python -c "import json_schema_validation as v; print(v.validate_app_metrics_schema('$metrics'))" 2>/dev/null || echo 1)
        if [[ (-n $metrics_validation_res) && ($metrics_validation_res -eq 0) ]] ; then
            #if scrap structure is valid, check optional fields (report_app, initiator, start_time, duration) and, if they don't present, set them
            if [[ "$3" != "null" ]] ; then
                # if 'initiator' was provided as shell parameter, use it to set 'initiator' field of all metrics
                metrics=$(echo "$metrics" | initiator=$3 yq -oj '(.[].initiator)=env(initiator)')
            else
                # else check if 'initiator' label is present in all metrics from notebook. If not, set default 'envchecker' value
                initiator_specified=$(echo "$metrics" | yq -oj '. | all_c(has("initiator"))')
                if [[ "$initiator_specified" == "false" ]] ; then
                    metrics=$(echo "$metrics" | yq -oj '(.[].initiator)="envchecker"')
                fi
            fi

            # if labels "report_app", "env", "scope" are not specified, set default value (null) for them
            metrics=$(echo "$metrics" | yq -oj '(.[] | (select (. | has("report_app") | not)) .report_app) |= "null"' \
                                    | yq -oj '(.[] | (select (. | has("env") | not)) .env) |= "null"'               \
                                    | yq -oj '(.[] | (select (. | has("scope") | not)) .scope) |= "null"')

            start_time_specified=$(echo "$metrics" | yq -oj '. | all_c(has("last_run"))')
            if [[ "$start_time_specified" == "false" ]] ; then
                start_millis=$(date -d "$(yq '.metadata.papermill.start_time' "$1")" +'%s%3N')
                metrics=$(echo "$metrics" | start_time=$start_millis yq -oj '(.[].last_run)=env(start_time)')
            fi


            nb_exec_duration=$(yq -oj '.metadata.papermill.duration' "$1" | awk '{print int( $1 * 1000 )}')
            metrics=$(echo "$metrics" | duration=$nb_exec_duration yq -oj '(.[] | (select (. | has("last_duration") | not)) .last_duration) |= env(duration)')

            # make all labels string values be in lowercase
            metrics=$(echo "$metrics" | yq -oj '(... | (select(tag=="!!str"))) |= downcase')
            # add label 's3_link' with default 'null' value and 'report_name' label to each metric in list
            echo "$metrics" | yq -oj ".[] += {\"s3_link\": \"null\", \"report_name\": \"$report_name\"}"
            return 0
        fi
    fi

    # if such scrap is not present in executed notebook, then determine metrics by papermill metadata
    notebook_meta=$(yq -oj '.metadata.papermill' "$1")
    start_millis=$(date -d "$(echo "$notebook_meta" | yq '.start_time')" +'%s%3N')
    duration=$(echo "$notebook_meta" | yq '.duration' | awk '{print int( $1 * 1000 )}';)
    initiator="envchecker"
    if [[ (-n $3) && ("$3" != "envchecker") ]] ; then
        initiator="$3"
    fi
    report_namespace="null"
    if [[ (-n $4) && ("$4" != "null") ]] ; then
        report_namespace="$4"
    fi
    nb_start=$start_millis duration_millis=$duration status=$2 initiator=$initiator report_name=$report_name report_namespace=$report_namespace \
    yq --null-input -oj '.last_run=env(nb_start) | .last_duration=env(duration_millis) | .status=env(status) | .report_namespace=strenv(report_namespace) | .report_app="null" | .initiator=strenv(initiator) | .s3_link="null" | .env="null" | .scope="null" | .report_name=strenv(report_name) | [.]'
}

# $1 - executed notebook path
reportToS3() {
    if printf '%s\n' "${reports[@]}" | grep -Fqw 's3'; then
        python -c "import infra.s3 as s3; s3.uploadReportsByExecutedNotebookPath('$1')"
    fi
}

# $1 - notebook name with full path
# $2 - list of parameters for notebook
# $3 - script name for result saving
runSingleNotebook() {

    script_path=$1
    if [[ ! -f $script_path ]]; then
        printf "ERROR: file %s does not exist or invalid\n" "$script_path"
        overall_result=1
        return 1
    fi

    # check params
    params=""
    if [[ -n $2 ]]; then
        params="$2"
    fi
    echo "Executed with params: $params"

    if [ -f /home/jovyan/shells/namespace_validator.sh ]; then
        # shellcheck disable=SC1091
        # shellcheck source=/home/jovyan/shells/namespace_validator.sh
        validation=$(. /home/jovyan/shells/namespace_validator.sh "$params")
    else
        validation=""
    fi
    if [ "$validation" != "" ]; then
        echo "$validation"
        overall_result=1
        return 1
    fi

    script_name=$(basename -- "$1")
    out_script_name_without_ext=$(get_out_script_name_without_ext "$script_name" "$3")
    echo "script name: $script_name"
    echo "out script name without extension: $out_script_name_without_ext"
    out_script_path="$out_path/${out_script_name_without_ext}.ipynb"

    if [[ -z $params ]]; then
        printf "run notebook %s\n" "$script_path"
        papermill "$script_path" -y "result_file_path: $out_script_name_without_ext" -y "out_path: $out_path" "$out_script_path"
    else
        printf "run notebook %s with params: \n" "$script_path"
        papermill "$script_path" -y "$params" -y "result_file_path: $out_script_name_without_ext" -y "out_path: $out_path" "$out_script_path"
    fi

    res=$(python /home/jovyan/utils/parseOut.py < "$out_script_path")
    outs=("$out_script_path")

    if [[ -z $res ]]; then
        res=False
    fi

    if [[ $res != "True" ]]; then
        overall_result=1
    fi
    initiator="envchecker"
    namespace="null"
    if [[ "$params" != "" ]]; then
        initiator=$(echo "$2" | yq -oy '.initiator // "envchecker" | downcase')
        namespace=$(echo "$2" | yq -oy '.namespace // "null" | downcase')
    fi
    metrics=$(extract_notebook_execution_metrics "$out_script_path" $overall_result "$initiator" "$namespace")
    outs=("$out_script_path")

    reportToPdf "$out_script_name_without_ext"
    outs=("${outs[@]}")
    params_as_json_str=$(echo "$params" | yq -oj -I0)
    if [[ -z "$params_as_json_str" || "$params_as_json_str" == "null" ]]; then params_as_json_str='{}'; fi

    outs_as_json_str=$(echo "[${outs//${IFS:0:1}/,}]" | yq -oj -I0)
    if [[ -z "$outs_as_json_str" || "$outs_as_json_str" == "null" ]]; then outs_as_json_str='[]'; fi

    output=$(python -c "import env_checker_utils as utils; print(utils.get_related_reports('$out_script_path','$outs_as_json_str','$out_path'))" 2>/dev/null || echo "[]")
    outs_as_json_str=$output
    yq ".checks += {\"path\":\"$script_path\", \"outs\": $outs_as_json_str, \"result\":\"$res\", \"params\":$params_as_json_str, \"metrics\":$metrics}" "$composite_result_file_path" -i || true
    reportToS3 "$out_script_path"
    reportToMonitoring "$out_script_path"

    echo "$res"
}

reportToPdf() {
   if $pdf_reporting_enabled ; then
        if printf '%s\n' "${reports[@]}" | grep -Fqw 'pdf'; then
            echo "report to $1.pdf"
            jupyter nbconvert --to pdf "$out_path/$1"
            outs+=("$out_path/$1.pdf")
        else
            echo "report to pdf is disabled"
        fi
  fi
}

reportToHtml() {
    if printf '%s\n' "${reports[@]}" | grep -Fqw 'html'; then
        html_reporting_enabled=true
    fi
    if $html_reporting_enabled ; then
        python /home/jovyan/utils/report_generator.py "$out_path"
    fi
}

reportToJson() {
    if printf '%s\n' "${reports[@]}" | grep -Fqw 'json'; then
        json_reporting_enabled=true
    fi
    if $json_reporting_enabled ; then
        /home/jovyan/utils/json_report_generator.py "$out_path"
    fi
}

reportToMonitoring() {
    if printf '%s\n' "${reports[@]}" | grep -Fqw 'monitoring'; then
        python -c "from monitoringUtils import MonitoringHelper; MonitoringHelper.pushNotebookExecutionResultsToMonitoringByExecutedNotebookPath('$1')"
    fi
}

# $1 - notebook_name
# $2 - mask (optional)
get_out_script_name_without_ext() {
    out_script_name_without_ext="$(basename "$1" .ipynb)"
    mask=$2
    if [[ -n $mask ]]; then
        out_script_name_without_ext="${mask/#\*/$out_script_name_without_ext}"
    fi
    curr_millis=$(date +%s%3N)
    echo "${out_script_name_without_ext}_${curr_millis}"
}

###START PROGRAM###

# Output of instructions if run.sh was launched without parameters
if [[ $# == 0 ]]; then
    print_usage
    exit 1
fi

if [ -f /home/jovyan/shells/set_paths.sh ]; then
    # shellcheck disable=SC1091
    # shellcheck source=/home/jovyan/shells/set_paths.sh
    # override PATH and PYTHONPATH variables
    source /home/jovyan/shells/set_paths.sh
fi

while getopts ":p:y:j:r:e:o:-:" opt; do
    case ${opt} in
    -)
        case "${OPTARG}" in
                *)
                # Handling other flags
                params="${params}
                ${OPTARG/'='/': '}"
                if [[ ${OPTARG} == "pdf=false" ]]; then
                    pdf_reporting_enabled=false
                fi
                if [[ ${OPTARG} == "html=true" ]]; then
                        html_reporting_enabled=true
                fi
                if [[ ${OPTARG} == "json=true" ]]; then
                        json_reporting_enabled=true
                fi
                if [[ ${OPTARG} == "clear=false" ]]; then
                        clear_out=false
                fi
                ;;
            esac
            ;;
    e)
        execute_pass=${OPTARG}
        execute_pass=${execute_pass//,/ } #replacement for env-checker-job for case when value for -e flag will be separated by ','
        echo "execute_pass: $execute_pass"
        executed_command="python $execute_pass"
        prepared_yaml=$(eval "$executed_command")
        echo "prepared yaml from -e flag: $prepared_yaml"
        ;;
    y)
        yaml_config=${OPTARG}
        echo "yaml config: $yaml_config"
        ;;
    j)
        json_config=${OPTARG}
        echo "json config: $json_config"
        ;;
    o)
        output_subfolder=${OPTARG}
        echo "output_subfolder: $output_subfolder"
        ;;
    r)
        DEFAULT_IFS=$IFS
        IFS=','
        read -ra reports <<< "${OPTARG}"
        IFS=$DEFAULT_IFS
        if [ ${#reports[@]} -gt 0 ]; then
            echo "${reports[@]}"
        fi
        ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        exit 0
        ;;
    ?)
        echo -e "Unrecognized option, OPTARG: $OPTARG"
        exit 0
        ;;
    esac
done

file_path=${*:$OPTIND:1}  #get value after all options (COMPOSITE_FILE_PATH|NOTEBOOK_FILE_PATH)

#Concatenate subfolders to './out' if they were passed using the '-o' flag
if [ -n "$output_subfolder" ]; then
    out_path="/home/jovyan/out/$output_subfolder"
else
    out_path="/home/jovyan/out"
fi

if [[ -n $json_config ]]; then
    prepareOutput
    echo "$json_config" > "$out_path/input.json"
    runComposite "$out_path/input.json"
elif [[ -n $yaml_config ]]; then
    prepareOutput
    echo "$yaml_config" > "$out_path/input.yaml"
    runComposite "$out_path/input.yaml"
elif [[ -n $prepared_yaml ]]; then
    prepareOutput
    echo "$prepared_yaml" > "$out_path/input.yaml"
    runComposite "$out_path/input.yaml"
elif [[ $file_path == *.ipynb ]]; then
    prepareOutput
    runSingleNotebook "$file_path" "$params"
elif [[ $file_path == *.yaml || $file_path == *.yml ]]; then
    prepareOutput
    runComposite "$file_path"
else
    printf "ERROR: file %s is not exist or invalid" "$file_path"
fi

echo "overall_result: $overall_result"
txt_result_file_path="$out_path/result.txt"
echo "$overall_result" >> "$txt_result_file_path"

reportToHtml
reportToJson
