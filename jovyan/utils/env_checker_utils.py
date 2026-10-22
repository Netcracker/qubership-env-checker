import base64
import os
import os.path
import datetime
import zipfile
from io import BytesIO
import requests
import yaml
import re
import scrapbook as sb
import json
import ast
import structured_log

log = structured_log.get_logger('env_checker_utils')


def get_env_variable_value_by_name(variable_name):
    env_variable = None
    path_to_env = "/etc/cloud-passport/" + variable_name
    if os.path.isfile(path_to_env):
        with open(path_to_env, 'r') as f:
            env_variable = f.read()

    if not env_variable:
        env_variable = os.getenv(variable_name)

    return env_variable


def get_default_env_variable_value_by_name(variable_name):
    env_variable = None
    path_to_env = "/etc/cloud-passport-defaults/" + variable_name
    if not os.path.isfile(path_to_env):
        # msg = f"Could not get default environment value {variable_name}."
        # print(colorize_text.get_red_text_color(msg))
        return None
    with open(path_to_env, 'r') as f:
        env_variable = f.read()

    return env_variable


global log_level
global production_mode
log_level = get_env_variable_value_by_name("ENVIRONMENT_CHECKER_LOG_LEVEL")
production_mode = get_env_variable_value_by_name("PRODUCTION_MODE")


def encode_to_base64(text: str) -> str:
    encoded_bytes = base64.b64encode(text.encode('utf-8'))
    encoded_string = encoded_bytes.decode('utf-8')
    return encoded_string


def get_content_from_file(path: str, file_name: str) -> str:
    file_path = os.path.join(path, file_name)
    # Check file is exists
    return get_content_from_file_by_path(file_path)


def get_content_from_file_by_path(path: str) -> str:
    # Check file is exists
    if os.path.isfile(path):
        file_extension = os.path.splitext(path)[1]
        # Read file
        if file_extension == '.pdf':
            return get_pdf_base64(path)
        else:
            return get_text_content_as_base64(path)
    # If file does not exists
    return None


def get_pdf_base64(file_path: str) -> str:
    with open(file_path, 'rb') as file:
        pdf_bytes = file.read()
        base64_pdf = base64.b64encode(pdf_bytes).decode('utf-8')
    return base64_pdf


def get_text_content_as_base64(file_path: str) -> str:
    with open(file_path, 'r', encoding='utf-8') as f:
        text_content = f.read()
    base64_content = base64.b64encode(text_content.encode('utf-8')).decode(
        'utf-8')
    return base64_content


def getCurrentTime() -> str:
    current_time = datetime.datetime.now().isoformat()
    if log_level != 'ERROR' and log_level is not None:
        log.debug('Current time resolved', current_time=current_time)
    return current_time


def is_production_mode() -> bool:
    if production_mode:
        return True
    return False


def is_log_level_defined() -> bool:
    return log_level is not None


def is_log_level_error() -> bool:
    return log_level == 'ERROR'


def is_log_level_over_error() -> bool:
    return is_log_level_defined and not is_log_level_error


def zip(filenames: list[str]) -> BytesIO:
    if not filenames:
        return
    zip_stream = BytesIO()
    with zipfile.ZipFile(zip_stream, 'w') as zip:
        for fname in filenames:
            zip.write(filename=fname, arcname=os.path.basename(fname))
    return zip_stream


def zipFilesWithTimestamp(filenames: list[str]) -> BytesIO:
    '''
    WARNING: must be used for run.sh only.
    '''
    if not filenames:
        return
    zip_stream = BytesIO()
    with zipfile.ZipFile(zip_stream, 'w') as zip:
        for fname in filenames:
            # take report name and cut off timestamp
            fname_in_archive = re.sub(r'(.*)(_\d+)(\.\w+$)', r'\1\3',
                                      os.path.basename(fname))
            zip.write(filename=fname, arcname=fname_in_archive)
    return zip_stream


def zip_reports_by_base_name(report_base_name) -> BytesIO:
    report_names = get_report_names_by_base_name(report_base_name)
    if report_names:
        return zip(report_names)


def get_report_names_by_base_name(report_base_name: str) -> list[str]:
    out_files_list = []
    for filename in os.listdir('out'):
        out_files_list.append(filename)
    if not out_files_list:
        log.warning('Output directory is empty', path='out')
        return out_files_list

    filtered_files_list = []
    for filename in out_files_list:
        if report_base_name in filename and not filename.endswith(
                '.txt'):  # ignoring .txt files with binary execution codes
            filtered_files_list.append(os.path.join('out', filename))

    if not filtered_files_list:
        log.warning('No reports found in the output directory',
                    report_base_name=report_base_name, path='out')
    elif log_level != 'ERROR' and log_level is not None:
        log.debug('Filtered report files', files=filtered_files_list,
                  file_count=len(filtered_files_list))

    return filtered_files_list


def check_connection_status(url, headers=None, path=''):
    try:
        response = requests.get(url + path, headers=headers, verify=False)
        if response.status_code == 200:
            log.info('Connection check succeeded', url=url + path,
                     status_code=response.status_code)
            return 1
        else:
            log.warning('Connection check failed', url=url + path,
                        status_code=response.status_code)
            return 0
    except Exception as e:
        log.exception('Connection check raised an error', url=url + path,
                      error=e)
        return 0


def zip_reports_by_executed_notebook_path(executed_notebook_path) -> BytesIO:
    report_names = get_report_names_from_result_file(executed_notebook_path)
    if report_names:
        return zipFilesWithTimestamp(report_names)


def get_related_reports(out_script_path, outs_as_json_str, out_path):
    nb = sb.read_notebook(out_script_path)
    out_list = ast.literal_eval(outs_as_json_str)
    if "custom_reports" in nb.scraps.data_dict:
        custom_reports = nb.scraps.data_dict["custom_reports"]
        if len(custom_reports) != 0:
            custom_reports = [
                out_path + "/" + report for report in custom_reports
            ]
            out_list.extend(custom_reports)
    return json.dumps(out_list)


def get_report_names_from_result_file(
    executed_notebook_path: str,
) -> list[str]:
    result = load_result_yml(os.path.dirname(executed_notebook_path))
    if result:
        for check in result['checks']:
            if executed_notebook_path in check['outs']:
                return check['outs']
    log.warning('Executed notebook not found in the result file',
                notebook_path=executed_notebook_path,
                result_file='result.yaml')


def load_result_yml(dir: str):
    """ Loads content of result.yaml file from provided directory.

    Parameters
    ----------
    dir : str
        path to directory, which contains result.yaml
    """

    with open(f"{dir}/result.yaml", "r") as stream:
        try:
            return yaml.safe_load(stream)
        except yaml.YAMLError as e:
            log.exception('Failed to parse the result file',
                          result_file=f'{dir}/result.yaml', error=e)
            return


def get_cloud_name() -> str:
    """
    Calculates cloud name from given cloud passport param CLOUD_PUBLIC_HOST
    """
    cloud_name = get_env_variable_value_by_name("CLOUD_PUBLIC_HOST")

    # Check if CLOUD_PUBLIC_HOST starts with 'apps.'
    if cloud_name.startswith("apps."):
        # Remove 'apps.' prefix
        cloud_name = cloud_name[5:]

    # Get substring before the first dot
    return cloud_name.split('.', 1)[0]
