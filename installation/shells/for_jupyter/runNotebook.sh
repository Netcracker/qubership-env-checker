#!/bin/bash

version_file_name=""     #File for checking versions of services. By default, the latest one is taken from the /versions folder.
full_script_name=""      #Full Notebook name with file path, for example: notebooks/Test.ipynb
script_name=""           #Notebook name without file path, for example: Test.ipynb
script_name_without_permission="" #Notebook name without file path and without extension, for example: Test
service_file_name=""     #Variable for the file name in case the checks are run in bulk

is_create_pdf=true       #Boolean variable set according to whether the "-i" flag was sent
is_check_from_file=false #Boolean variable if "value=true" - Notebooks check will be done from file

available_scripts=()     #Stores all Python scripts in the /notebooks folder
file_content=()          #Version file content - needed for version comparison and alias search

s3_integration_enabled=false
monitoring_integration_enabled=false

outputProgramInfo(){
    echo -e "\nScript for checking the health of services for the environment. The script is used in \033[1m options:\033[0m"

    echo -e "\033[1m1.\033[0m Checking a specific service, in this case, the performance of the service, version, and connectivity checks is checked."
    echo -e "   \033[1musage:\033[0m ./runNotebook.sh [-s SCRIPT_NAME] [-n NAMESPACE] [-f FILE_NAME] [-v VERSION_FILE_NAME] [-i]"

    echo -e "   \033[1mflags (m-mandatory, o-optional):\033[0m"
    echo -e "   \033[1m  -s            (m)\033[0m  #The name of Notebook script which will be run. Can be used with the '-v', '-n' flags"
    echo -e "   \033[1m  -n            (o)\033[0m  #The namespace for which the service will be checked. Can be used with the '-s', '-v' flags"
    echo -e "   \033[1m  -i            (o)\033[0m  #Flag for disabling the creation of .pdf files. By default, .pdf's are created. Can be used with the '-s', '-f', '-v', '-n', flags"
    echo -e "   \033[1m  -f            (o)\033[0m  #The flag is used to check services and their namespaces from a file. Can be used with the '-v' flag"
    echo -e "   \033[1m  -v            (o)\033[0m  #Flag for specifying the name of the .yaml file that will be used for version checking. Can be used with the '-s', '-n', '-v' flags"
    echo -e "   \033[1m  --s3          (o)\033[0m  #Flag, which enables sending of generated check results to S3 bucket. Can be used with the '-s', '-f', '-v', '-n', '-i', '--monitoring' flags"
    echo -e "   \033[1m  --monitoring  (o)\033[0m  #Flag, which enables sending of generated check results to monitoring system. Can be used with the '-s', '-f', '-v', '-n', '-i', '--s3' flags"


    echo -e "   \033[1musage example:\033[0m"
    echo -e "      ./runNotebook.sh -f Test.yaml                                  \033[36m#Start checking all services and namespaces described in the Test.yaml file\033[0m"
    echo -e "      ./runNotebook.sh -s notebooks/Test.ipynb -v release1.0.0.yaml   \033[36m#Run a notebook with checking component versions.\033[0m"
    echo -e "      ./runNotebook.sh -s notebooks/Test.ipynb -n namespace_name     \033[36m#Run a notebook for a 'namespace_name' namespace.\033[0m"
    echo -e "      ./runNotebook.sh -s notebooks/Test.ipynb --monitoring          \033[36m#Run a notebook and send its execution results to monitoring system as metrics.\033[0m"
    echo -e "      ./runNotebook.sh -s notebooks/Test.ipynb --monitoring --s3     \033[36m#Run a notebook and send its execution results to monitoring system and s3.\033[0m"

    echo -e "   \033[1moutput:\033[0m The result is available in .pdf format in the /out folder"
    echo -e ""
}

# Recursively getting all possible notebooks to run
function getAllNotebooks() {
    for notebook_item in "$1"/*
    do
        if [[ -d "$notebook_item" ]] ; then
            getAllNotebooks "$notebook_item"
        elif [[ "$notebook_item" == *.ipynb ]]; then
            current_file_path=$(realpath "$notebook_item")
            available_scripts+=("${current_file_path//\/home\/jovyan\///}")
        fi
    done
}

# Checking whether a particular notebook can be started
checkNotebookForAvailability() {
    local error_occurred=1
    local error_script=""

    for param in "$@"; do
        for a_serv in "${available_scripts[@]}"; do
            if [[ " ${a_serv} " =~ ${param} ]]; then
                error_occurred=1
                break
            else
                error_script=$param
                error_occurred=0
            fi
        done

        if [[ "$error_occurred" == 0 ]]; then
            string_available_list=$(printf "%s\n" "${available_scripts[@]}")
            echo -e "\e[41m\e[37mWrong script - {$error_script}! The following script(s) are available for verification:\e[0m"
            for script in ${string_available_list}
                do
                    echo -e "\e[41m\e[37m${script}\e[0m"
                done

            break
        fi
    done

    return $error_occurred
}

getVersionFileContent()
{
    readarray file_content < "/home/jovyan/$version_file_name"
    file_content=("${file_content[@]// /}") # remove spaces
    file_content=("${file_content[@]/$'\r'/}") # remove carriage return
    file_content=("${file_content[@]/$'\n'/}") # remove newline
    # shellcheck disable=SC2207
    file_content=($(echo "${file_content[@]}" | grep -v '^#')) # remove comments
}

getNamespaceAliasByNotebookName()
{
    alias=""

    for line in "${file_content[@]}"
    do
        match=$(echo "$line" | grep "$1:")
        if [[ -n "$match" ]]; then
            alias=$(echo "$line" | cut -d ":" -f 2)
        fi
    done
    echo "$alias"
}

cloudPassportSending()
{
    papermill ./"$full_script_name" ./out/"$script_name" -p required_app_domain "$required_app_domain"
    # shellcheck disable=SC2002
    result=$(cat ./out/"$script_name" | ./utils/parseOut.py)

    #if flag -i was not sent - not create .pdf
    if [ "$is_create_pdf" = true ]; then
        jupyter nbconvert --to pdf ./out/"$script_name"
    fi

    #case when script fails until the end of running
    if [ -z "$result" ]; then
        result='False'
    fi
    echo $result
    
    python -c "import nb_data_manipulation_utils; nb_data_manipulation_utils.validate_and_save_metrics('out/CloudPassportLayoutCheck.ipynb')" > /dev/null

    if $s3_integration_enabled ;
    then
        sendResultsToS3 'CloudPassportLayoutCheck'
    fi

    if [[ "$monitoring_integration_enabled" == true ]];
    then
        sendResultsToMonitoring 'CloudPassportLayoutCheck'
    fi

}

# $1 - keyword taken from the dictionary to search for namespaces
# $2 - notebook name with file format
runNotebookWithSearchingNamespace() {
    notebook=$(echo "$2" | cut -d "." -f 1)
    ns_list=$(kubectl get ns | grep "$1" | awk '{print $1}')

    if [ -z "$ns_list" ]; then
        echo "No namespaces found in Kubernetes for \"$1\" alias"
        return
    fi

    for NS in $ns_list;
    do
        echo "Script - $2 has been run for Namespace $NS"
        executed_nb="$notebook"-"${NS}"
        papermill ./$full_script_name ./out/"$executed_nb".ipynb -p namespace "$NS" -p version_file_name $version_file_name -p bulk_check_file_name "${short_file}Result.yaml"
        result=$(./utils/parseOut.py < ./out/"${executed_nb}.ipynb")

        #if flag -i was not sent - not create .pdf
        if [ "$is_create_pdf" = true ]; then
            jupyter nbconvert --to pdf ./out/"$executed_nb".ipynb
        fi

        #If it is not executed in bulk, we create a .txt file with the result of execution
        if [ -z "$service_file_name" ]; then
            fillTxtResultFile "$result" $script_name_without_permission
        fi
        echo "$result"

        python -c "import nb_data_manipulation_utils; nb_data_manipulation_utils.validate_and_save_metrics('./out/${executed_nb}.ipynb')" > /dev/null

        if [ "$s3_integration_enabled" = true ];
        then
            sendResultsToS3 "$executed_nb"
        fi

        if [[ "$monitoring_integration_enabled" == true ]];
        then
            sendResultsToMonitoring "$executed_nb"
        fi
    done
}

# $1 - file name with extension
# $2 - namespace
runFullCheckNotebookWithNamespace()
{
    notebook="$(basename "$1" .ipynb)"
    #there is a checked namespace?
    executed_nb="$notebook-$2"
    if kubectl get ns "$2" >/dev/null 2>/dev/null; then
        papermill ./$full_script_name ./out/$executed_nb.ipynb -p namespace "$2" -p version_file_name $version_file_name -p bulk_check_file_name "${short_file}Result.yaml"
        result=$(./utils/parseOut.py < ./out/"$executed_nb.ipynb")
        #if flag -i was not sent - not create .pdf
        if [ "$is_create_pdf" = true ]; then
            jupyter nbconvert --to pdf ./out/"$executed_nb".ipynb
        fi
        #If it is not executed in bulk, we create a .txt file with the result of execution
        if [ -z "$service_file_name" ]; then
            fillTxtResultFile "$result" "$notebook"
        fi
        echo "$result"
    
        python -c "import nb_data_manipulation_utils; nb_data_manipulation_utils.validate_and_save_metrics('./out/${executed_nb}.ipynb')" > /dev/null

        if [ "$s3_integration_enabled" = true ];
        then
            sendResultsToS3 "$executed_nb"
        fi

        if [[ "$monitoring_integration_enabled" == true ]];
        then
            sendResultsToMonitoring "$executed_nb"
        fi
        
    else
        echo -e "\e[41m\e[37mThe namespace $2 does not exist. Verification script will not be executed for $2\e[0m"
    fi
}

# $1 - notebook name
singleCallNotebookByName()
{
    #find alias for search service namespaces
    alias=$(getNamespaceAliasByNotebookName "$1")
    #call the Python script
    if [ -n "$alias" ]; then
        # case where alias was found and script use autodiscovery
        echo "Found alias - {$alias} for script - {$1}"
        runNotebookWithSearchingNamespace "$alias" "$1"
    else
        # run custom script without arguments
        papermill ./$full_script_name ./out/$script_name
        result=$(./utils/parseOut.py < ./out/"$script_name")
        #if flag -i was not sent - not create .pdf
        if [ "$is_create_pdf" = true ]; then
            jupyter nbconvert --to pdf ./out/$script_name
        fi
        #If it is not executed in bulk, we create a .txt file with the result of execution
        if [ -z "$service_file_name" ]; then
            fillTxtResultFile "$result" $script_name_without_permission
        fi
        echo "$result"
        
        python -c "import nb_data_manipulation_utils; nb_data_manipulation_utils.validate_and_save_metrics('./out/${script_name}')" > /dev/null
        
        if [ "$s3_integration_enabled" = true ];
        then
            sendResultsToS3 "$script_name"
        fi

        if [[ "$monitoring_integration_enabled" == true ]];
        then
            sendResultsToMonitoring "$script_name"
        fi
    fi
}

# Bulk launch of notebooks via file
# $1 - the name of the .yaml file from which the scripts are run
checkNotebooksFromFile()
{
    file=$1                             #filename with extension
    short_file="$(basename "$1" .yaml)" #filename without extension
    #recreate file with short result list (0 - success result ;1 - failed result)
    if [ -f "./out/${short_file}.txt" ]; then
        rm "./out/${short_file}.txt"    #delete .txt file with short result list
    fi
    touch "./out/${short_file}.txt"     #create .txt file for short list of result

    while read -r line; do
        # $key - full path to Notebook script
        # $value - namespace
        read -r key value <<< "$(awk '{gsub(/:/," "); print $1, $2}' <<< "$line")"

        #If the variable is empty - run without parameters otherwise run for namespace
        if [ -z "$value" ]; then
            script_name="$(basename "$key")"
            full_script_name=$key
            #Special logic for CloudPassportLayout
            if [[ $script_name == "CloudPassportLayoutCheck.ipynb" ]]; then
                cloudPassportSending
            else
                singleCallNotebookByName "$script_name"
                python -c "import reportResultDumper; reportResultDumper.generateReportFromResultDump('out/$short_file' + 'Result.yaml', '$short_file' + 'Table.html')"
            fi
        else
            if ! checkNotebookForAvailability "$key"; then
                full_script_name="$key"
                runFullCheckNotebookWithNamespace "$key" "$value"
                python -c "import reportResultDumper; reportResultDumper.generateReportFromResultDump('out/$short_file' + 'Result.yaml', '$short_file' + 'Table.html')"
            fi
        fi    

    #send data to result .txt file
    if [[ $result == "False" ]]; then
        echo "1" >> ./out/"${short_file}.txt"
    else
        echo "0" >> ./out/"${short_file}.txt"
    fi

    done < "$file"
}

# Gets the most recent version of a file from the ./versions folder
getLastVersionFile(){
    # shellcheck disable=SC2164
    cd versions
    latest_file=$(find . -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n | tail -n1 | cut -d ' ' -f2-) #was - latest_file="$(ls -v | tail -n1)"
    cd ..
    if [ -z "$latest_file" ]; then
        echo "Unable to find the latest version file."
        echo "runNotebook.sh Exit Code: 1"
        exit 1
    fi
    echo "$latest_file"
}

# Checking whether execution rights are required after installations
smokeTestKubectlCommand(){
    check_access_command="kubectl get namespaces"
    if ! result=$($check_access_command 2>&1); then
        echo "Error: $result"
        echo "runNotebook.sh Exit Code: 1"
        exit 1
    fi
}

# $1 - Check result (True or False)
# $2 - filename (how to call a new .txt file)
fillTxtResultFile(){
    if [[ $1 == "False" ]]; then
        echo "1" > ./out/"$2".txt
    else
        echo "0" > ./out/"$2".txt
    fi
}

# $1 - executed notebook name
sendResultsToS3() {
    report_base_name="$(basename "$1" .ipynb)"
    python -c "import infra.s3 as s3; s3.uploadReports('$report_base_name')"
}

# $1 - executed notebook name
sendResultsToMonitoring() {
    report_base_name="$(basename "$1" .ipynb)"
    python -c "from monitoringUtils import MonitoringHelper; MonitoringHelper.pushNotebookExecutionResultsToMonitoring('$report_base_name')"
}

###START PROGRAM###
while getopts ":s:n:f:d:v:-:ih" opt; do
    case ${opt} in
    -)
        case "${OPTARG}" in
            s3)
                s3_integration_enabled=true
                ;;
            monitoring)
                monitoring_integration_enabled=true
                ;;
            *)
                echo "Invalid option --${OPTARG}" >&2
                echo "runNotebook.sh Exit Code: 1"
                exit 1
        esac
        ;;
    d)
        echo -e "\e[43m\e[37mSet values for '-d' flag if notebook accepts it as a parameter\e[0m"
        required_app_domain=${OPTARG}
        ;;
    s)
        full_script_name=${OPTARG}
        script_name=$(basename -- "$full_script_name")
        script_name_without_permission=$(basename "$script_name" .ipynb)
        ;;
    n)
        namespace_list=${OPTARG}
        ;;
    f)
        # shellcheck disable=SC2034
        is_check_from_file=true
        service_file_name=${OPTARG}
        ;;
    v)
        version_file_name=${OPTARG}
        ;;
    i)
        is_create_pdf=false
        ;;
    h)
        outputProgramInfo
        echo "runNotebook.sh Exit Code: $?"
        exit 0
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        echo "runNotebook.sh Exit Code: 1"
        exit 1
        ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        echo "runNotebook.sh Exit Code: 1"
        exit 1
        ;;
    esac
done

smokeTestKubectlCommand
source /home/jovyan/shells/set_paths.sh

if [ -z "$script_name" ] && [ -z "$service_file_name" ]; then
    echo -ne "\033[31mNot enough flags were specified\033[0m\n"
    outputProgramInfo
    echo "runNotebook.sh Exit Code: $?"
    exit 1
fi

#Trying to define the version file. If it is not specified explicitly, we take the latest one from the "versions/" folder
if [ -z "$version_file_name" ]; then
    version_file_name="versions/$(getLastVersionFile)"
    echo "Version file with last version is: $version_file_name"
fi
getVersionFileContent

getAllNotebooks "$(pwd)"
echo -ne "\033[34mRelative script path:\033[0m $full_script_name\n"
echo -ne "\033[34mCheck script(s):\033[0m $script_name\n"
echo -ne "\033[34mFile name without extension:\033[0m $script_name_without_permission\n"
echo -ne "\033[34mFile version name:\033[0m $version_file_name\n"
echo -ne "\033[34mNamespace(s):\033[0m $namespace_list\n"
echo -ne "\033[34mService file name:\033[0m $service_file_name\n"
echo -ne "\033[34mRequired App\Domain:\033[0m $required_app_domain\n"
mkdir -p out
rm -rf out/*

if [ -n "$script_name" ] && [ -z "$namespace_list" ] && [ -z "$service_file_name" ]; then
    echo "Call with file_name argument(s) without namespaces"

    if ! checkNotebookForAvailability "$full_script_name"; then
        if [[ $script_name == "CloudPassportLayoutCheck.ipynb" ]]; then
            cloudPassportSending
            fillTxtResultFile "$result" "$script_name_without_permission"
        else
            singleCallNotebookByName "$script_name"
        fi
        echo "runNotebook.sh Exit Code: $?"
        exit 0
    fi
fi

if [ -n "$script_name" ] && [ -n "$namespace_list" ] && [ -z "$service_file_name" ]; then
    echo "Call with file_name argument(s) and with namespace(s)"
    if ! checkNotebookForAvailability "$full_script_name"; then
        runFullCheckNotebookWithNamespace "$script_name" "$namespace_list" "None"
    fi
    echo "runNotebook.sh Exit Code: $?"
    exit 0
fi

if [ -z "$script_name" ] && [ -z "$namespace_list" ] && [ -n "$service_file_name" ]; then
    echo "Checks from the file - $service_file_name will be performed"
    checkNotebooksFromFile "$service_file_name"
    rm "out/$short_file"Result.yaml
    mv "$short_file"Table.html out/

    if $s3_integration_enabled ;
    then
        echo "Sending bulk check result for $short_file.yaml file to S3"
        python -c "import infra.s3 as s3; s3.uploadBulkCheckTable('$short_file')"
    fi

    echo "runNotebook.sh Exit Code: $?"
    exit 0
fi