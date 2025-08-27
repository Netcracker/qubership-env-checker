import os
import yaml
import drowingModule
import connectivityHelper
from enum import Enum
from reportResultDTO import ReportResultDTO
from reportResultDTO import CheckFinStatus
from table_plotter import Table

def __getNamespaces__(temp_resultdump_filename: str) -> list[str]:
    """
    Get names of all namespaces that were validated and are documented in the `temp_resultdump_filename` yaml
    """
    with open(temp_resultdump_filename, 'r') as file:
        yaml_data = yaml.load(file, Loader=yaml.Loader)
    namespaces = []
    for key, value in yaml_data.items():
        if isinstance(value, list):
            for report in value:
                namespaces.append(report['namespace'])
    return list(set(namespaces))

def __getValidations__(temp_resultdump_filename: str) -> list[str]:
    """
    Get names of all validations that are documented in the `temp_resultdump_filename` yaml
    """
    with open(temp_resultdump_filename, 'r') as file:
        yaml_data = yaml.load(file, Loader=yaml.Loader)
    validation_types = []
    for key, value in yaml_data.items():
        if isinstance(value, list):
            validation_types.append(key)
    return validation_types

def __getValidationResultsByNamespace__(temp_resultdump_filename: str, namespace: str) -> list[tuple[int, str]]:
    """
    Get all validation results that was performed for the particular namespace\n
    Returns a list of tuples where (validation status AKA `CheckFinStatus.value`, validation result message)\n
    `temp_resultdump_filename`: yaml file where validation results info was recorded
    """
    with open(temp_resultdump_filename, 'r') as file:
        yaml_data = yaml.load(file, Loader=yaml.Loader)

    validations = __getValidations__(temp_resultdump_filename)

    results = []
    for validation in validations:
        found = False
        for record in yaml_data[validation]:
            if record['namespace'] == namespace:
                found = True
                results.append((record["status"], record["message"]))
                break
        if not found:
            results.append(('', ''))

    return results
            

def generateReportFromResultDump(temp_resultdump_filename: str, final_report_filename: str) -> None:
    """
    Generate HTML report table with the results of all validations ran. Validation results must be collected with writeResultRecord()
    before running this.\n
    `temp_resultdump_filename`: file where validation results info was recorded, should be a yaml file and be looking
    like this:
    ```
    validation_name1:
    - namespace: namespace1
      status: 0
      message: "Successfully passed!"
    validation_name2:
    - namespace: namespace1
      status: 1
      message: "Failed! Couldn't validate port"
    ```
    `final_report_filename`: result html file to generate a report in, will be rewritten if already exists
    """
    validation_types = __getValidations__(temp_resultdump_filename)
    namespaces = __getNamespaces__(temp_resultdump_filename)
    
    table = Table()
    table.start(final_report_filename, ['', 'namespace'] + validation_types, 'Grey', 'White')

    for index, namespace in enumerate(namespaces):
        results = __getValidationResultsByNamespace__(temp_resultdump_filename, namespace)
        statuses = []
        messages = []
        for result in results:
            statuses.append(CheckFinStatus(result[0]).name if result[0] != '' else '')
            messages.append(result[1])

        colors = []    
        for status in statuses:
            match status:
                case CheckFinStatus.OK.name:
                    colors.append('DarkSeaGreen')
                case CheckFinStatus.ERROR.name:
                    colors.append('DarkSalmon')
                case CheckFinStatus.NONE.name:
                    colors.append('LightGray')
                case '':
                    colors.append('White')
        table.row([f'<b style="color: White">{index+1}</b>', namespace] + statuses, tooltips=['', ''] + [f'<span style="font-size: 11px">{message}</span>' for message in messages], color_cell=['Grey', ''] + colors)

    table.fin()


def writeResultRecord(filename: str, validation_name: str, reportdto: ReportResultDTO) -> None:
    """
    Add a record with validation result information inside a temporary file. Use this to collect all validation results before running generateReportFromResultDump()\n
    `filename`: yaml filename to write result records to\n
    `validation_name`: name of the validation that was executed to get the result(examples: "Endpoint", "Authorized call", "Last logs")\n
    `reportdto`: object containing validation result information like status, message, namespace where validation took place
    """
    if reportdto.get_namespace() == None:
        raise Exception('Can\'t write validation result record - namespace is None, should be str')
    if reportdto.get_status() == None:
        raise Exception('Can\'t write validation result record - Status is None, should be CheckFinStatus')
    
    new_record = {
        "message": reportdto.get_message(),
        "status": reportdto.get_status().value,
        "namespace": reportdto.get_namespace()
    }
    
    try:
        filename = 'out/' + filename
        with open(filename, 'r') as file:
            yaml_data = yaml.load(file, Loader=yaml.Loader)
    except:
        yaml_data = {}

    if validation_name not in yaml_data:
        yaml_data[validation_name] = []

    yaml_data[validation_name].append(new_record)
    try:
        with open(filename, 'a+') as file:
            file.seek(0)
            file.truncate()
            yaml.dump(yaml_data, file)
    except PermissionError:
        log_level = connectivityHelper.getEnvVariableValueByName("ENVIRONMENT_CHECKER_LOG_LEVEL")
        if log_level != 'ERROR' and log_level is not None:
            print("\x1b[33mFile " + filename + " not created. The writeResultRecord method should only be called for bulk running. Try running it through the .runNotebooks.sh script. \x1b[0m")