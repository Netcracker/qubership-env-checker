import yaml
import sys
import os
import nbformat
import env_checker_utils
import datetime
import scrapbook as sb
import constants
import json_schema_validation
import json

from pathlib import Path
from NotebookMetrics import NotebookMetrics

S3_STORAGE_SERVER_URL = env_checker_utils.get_env_variable_value_by_name('STORAGE_SERVER_URL')
BUCKET_NAME = env_checker_utils.get_env_variable_value_by_name('ENVCHECKER_STORAGE_BUCKET')
S3_LINK = f'{S3_STORAGE_SERVER_URL}/{BUCKET_NAME}' 
UPLOADED_TO_S3 = 'uploaded_to_s3'
ENV_CHECKER = 'env-checker'
METRICS = 'metrics'


def validate_and_save_metrics(executed_nb_path):
    '''
    WARNING: must be used only within runNotebook.sh!
    '''

    nb_scraps = sb.read_notebook(executed_nb_path).scraps.data_dict
    nb = nbformat.read(executed_nb_path, nbformat.NO_CONVERT)
    nb_meta = nb["metadata"]
    nb_meta_papermill = nb_meta["papermill"]
    nb_duration = int(nb_meta_papermill["duration"] * 1000)
    nb_start_time = parse_papermill_start_time(nb_meta_papermill["start_time"])
    nb_name = Path(executed_nb_path).stem.lower()

    # check if scrap with metric is present in notebook. If not, or if metrics are scraped incorrectly, calculate metrics by 
    # papermill metadata
    if METRICS not in nb_scraps or not json_schema_validation.validate_app_metrics_schema_as_dict(nb_scraps[METRICS]):
        try:
            for cell in nb['cells'][::-1]:
                metadata = cell['metadata']
                if 'tags' in metadata:
                    tags = metadata['tags']
                    if 'result' in tags:
                        nb_result = 0 if cell['outputs'][0]['data']['text/plain'] == 'True' else 1
        except KeyError:
            print(f"Could not find result tag in notebook: {executed_nb_path}.ipynb")
            sys.exit(1)
        ns = 'null'
        app = 'null'
        res = [{constants.REPORT_NAME_LABEL: nb_name, constants.STATUS: nb_result, constants.LAST_DURATION: nb_duration, 
                constants.LAST_RUN: nb_start_time, constants.REPORT_NAMESPACE_LABEL: ns, constants.REPORT_APP_LABEL: app, 
                constants.INITIATOR_LABEL: constants.DEFAULT_INITIATOR, constants.S3_LINK_LABEL: 'null'}]
    # if scrap is present and valid, check for missing optional label values, set them, and save in notebook
    else:
        metrics = nb_scraps[METRICS]
        # If at least 1 metric doesn't contain 'start_time' or 'initiator' labels, these labels should be updated for every metric
        # It is needed for creating correct metrics for monitoring
        for m in metrics:
            if constants.LAST_RUN not in m:
                for m in metrics:
                    m[constants.LAST_RUN] = nb_start_time
                break
        for m in metrics:
            if constants.INITIATOR_LABEL not in m:
                for m in metrics:
                    m[constants.INITIATOR_LABEL] = constants.DEFAULT_INITIATOR
                break
        res = []
        for m in metrics:
            if constants.LAST_DURATION not in m:
                m[constants.LAST_DURATION] = nb_duration
            if constants.REPORT_APP_LABEL not in m:
                m[constants.REPORT_APP_LABEL] = 'null'
            res.append({constants.REPORT_NAME_LABEL: nb_name, constants.STATUS: m[constants.STATUS], 
                        constants.LAST_DURATION: m[constants.LAST_DURATION], constants.LAST_RUN: m[constants.LAST_RUN], 
                        constants.INITIATOR_LABEL: m[constants.INITIATOR_LABEL], 
                        constants.REPORT_NAMESPACE_LABEL: m[constants.REPORT_NAMESPACE_LABEL].lower(), 
                        constants.REPORT_APP_LABEL: m[constants.REPORT_APP_LABEL].lower(),
                        constants.S3_LINK_LABEL: 'null'})
    nb_meta[ENV_CHECKER] = {METRICS: res}
    nbformat.write(nb, executed_nb_path)

def extract_notebook_execution_data(notebook_base_name: str) -> list[NotebookMetrics]:
    '''
    WARNING: must be used only for runNotebook.sh
    '''

    nb_path = f'out/{notebook_base_name}.ipynb'
    nb = nbformat.read(nb_path, nbformat.NO_CONVERT)
    nb_meta = nb['metadata']
    if ENV_CHECKER in nb_meta:
        env_checker_meta = nb_meta[ENV_CHECKER]
        metrics = env_checker_meta[METRICS]
        res = []
        for m in metrics:
            res.append(NotebookMetrics(report_name=m[constants.REPORT_NAME_LABEL], status=m[constants.STATUS], last_duration=m[constants.LAST_DURATION],
                                        last_run=m[constants.LAST_RUN], s3_link=m[constants.S3_LINK_LABEL], initiator=m[constants.INITIATOR_LABEL], 
                                        report_namespace=m[constants.REPORT_NAMESPACE_LABEL], report_app=m[constants.REPORT_APP_LABEL]))
        return res
    print(f'No metrics data was recorded in {nb_path}')
    sys.exit(1)

def extract_notebook_execution_data_from_result_file(executed_notebook_path: str) -> list[NotebookMetrics]:
    '''
    WARNING: must be used only for run.sh
    '''

    result_file_content = env_checker_utils.load_result_yml(os.path.dirname(executed_notebook_path))
    if result_file_content:
        for check in result_file_content['checks']:
            if executed_notebook_path in check['outs']:
                res = []
                if METRICS in check:
                    metrics = check[METRICS]
                    for m in metrics:
                        report_name = extract_label_value_from_result_metric(executed_notebook_path, m, constants.REPORT_NAME_LABEL)
                        status = extract_label_value_from_result_metric(executed_notebook_path, m, constants.STATUS)                        
                        last_duration = extract_label_value_from_result_metric(executed_notebook_path, m, constants.LAST_DURATION)
                        last_run = extract_label_value_from_result_metric(executed_notebook_path, m, constants.LAST_RUN)
                        report_app = extract_label_value_from_result_metric(executed_notebook_path, m, constants.REPORT_APP_LABEL)
                        report_namespace = extract_label_value_from_result_metric(executed_notebook_path, m, constants.REPORT_NAMESPACE_LABEL)
                        initiator = extract_label_value_from_result_metric(executed_notebook_path, m, constants.INITIATOR_LABEL)
                        s3_link = extract_label_value_from_result_metric(executed_notebook_path, m, constants.S3_LINK_LABEL)
                        env = extract_label_value_from_result_metric(executed_notebook_path, m, constants.ENV_LABEL)
                        scope = extract_label_value_from_result_metric(executed_notebook_path, m, constants.SCOPE_LABEL)

                        res.append(NotebookMetrics(report_name=report_name, status=status, last_duration=last_duration, last_run=last_run, 
                                                   report_namespace=report_namespace, s3_link=s3_link, report_app = report_app, initiator = initiator,
                                                   env=env, scope=scope))
                else:
                    print(f"Could not extract 'metrics' section from result.yaml for executed notebook: {executed_notebook_path}")
                    sys.exit(1)
                return res
        print(f'Cannot find {executed_notebook_path} in result.yaml')
        sys.exit(1)

def extract_label_value_from_result_metric(executed_nb_path: str, metric: dict, label_name: str):
    if label_name in metric:
        return metric[label_name]
    else:
        raise ValueError(f"Could not extract {label_name} of executed notebook from result.yaml: {executed_nb_path}")

def extract_notebook_execution_data_for_s3_pushing(notebook_base_name: str) -> dict:
    '''
    WARNING: must be used only in case if notebook was executed via runNotebook.sh
    
    Extracts 'last_run', 'initiator' labels of executed notebook as a dict. These labels are needed for 
    uploading notebook reports to s3.
    '''
    
    nb = nbformat.read(f'out/{notebook_base_name}.ipynb', nbformat.NO_CONVERT)
    try:
        metrics = nb['metadata'][ENV_CHECKER][METRICS][0]
        return {constants.LAST_RUN: metrics[constants.LAST_RUN], constants.INITIATOR_LABEL: metrics[constants.INITIATOR_LABEL]}
    except Exception:
        print(f"Could not extract execution metrics of notebook: {notebook_base_name}.ipynb")
        sys.exit(1)

def extract_nb_execution_data_from_result_file_for_s3_pushing(executed_notebook_path: str) -> dict:
    result_file_content = env_checker_utils.load_result_yml(os.path.dirname(executed_notebook_path))
    if result_file_content:
        for check in result_file_content['checks']:
            if executed_notebook_path in check['outs']:
                res = []
                if METRICS in check:
                    m = check[METRICS][0]
                    return {
                        constants.REPORT_NAME_LABEL: extract_label_value_from_result_metric(executed_notebook_path, m, constants.REPORT_NAME_LABEL),
                        constants.INITIATOR_LABEL: extract_label_value_from_result_metric(executed_notebook_path, m, constants.INITIATOR_LABEL),
                        constants.LAST_RUN: extract_label_value_from_result_metric(executed_notebook_path, m, constants.LAST_RUN),
                        constants.ENV_LABEL: extract_label_value_from_result_metric(executed_notebook_path, m, constants.ENV_LABEL),
                        constants.SCOPE_LABEL: extract_label_value_from_result_metric(executed_notebook_path, m, constants.SCOPE_LABEL)    
                    }
                else:
                    print(f"Could not extract 'metrics' section from result.yaml for executed notebook: {executed_notebook_path}")
                    sys.exit(1)
                return res
        print(f'Cannot find {executed_notebook_path} in result.yaml')
        sys.exit(1)

def parse_papermill_start_time(start_time_str: str) -> int:
    dt_obj = datetime.datetime.strptime(start_time_str, '%Y-%m-%dT%H:%M:%S.%f')    
    return int(dt_obj.timestamp() * 1000)

def update_s3_link_label_for_notebook(notebook_base_name: str):
    notebook_path = f'out/{notebook_base_name}.ipynb'
    if os.path.isfile(notebook_path):
        notebook = nbformat.read(notebook_path, nbformat.NO_CONVERT)
        for m in notebook['metadata'][ENV_CHECKER][METRICS]:
            m[constants.S3_LINK_LABEL] = S3_LINK
        nbformat.write(notebook, notebook_path)
    else:
        print(f'Cannot find report: ${notebook_path}')

def update_s3_link_label_for_notebook_from_result_file(executed_notebook_path: str):
    result_yml_dir_location = os.path.dirname(executed_notebook_path)
    result = env_checker_utils.load_result_yml(result_yml_dir_location)
    if result:
        for check in result['checks']:
            if executed_notebook_path in check['outs']:
                for m in check[METRICS]:
                    m[constants.S3_LINK_LABEL] = S3_LINK
                with open(f'{result_yml_dir_location}/result.yaml', 'w') as result_yml:
                    yaml.dump(result, result_yml, default_flow_style=False)
                return
        print(f'Cannot find {executed_notebook_path} in result.yaml')

def extract_metrics_from_nb_scraps(executed_notebook_path) -> bool:
    nb = sb.read_notebook(executed_notebook_path)
    try:
        print(json.dumps(nb.scraps.data_dict[METRICS]))
    except KeyError:
        print('{}')