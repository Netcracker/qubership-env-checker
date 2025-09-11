import urllib3
import logging
import boto3
import nb_data_manipulation_utils
import env_checker_utils
import time
import constants
import traceback
import sys
import re
import os
import pytz
import uuid

from pathlib import Path
from botocore.exceptions import ClientError
from botocore.client import Config
from result import Result, ResultStatus
from datetime import datetime
from errorCode import ErrorCode

log_level = env_checker_utils.get_env_variable_value_by_name('ENVIRONMENT_CHECKER_LOG_LEVEL')
urllib3.disable_warnings()

REPORT_FULL_URL_TEMPLATE = '{s3_server_url}/{bucket_name}/{bucket_to_report_path}'
REPORT_PATH_TEMPLATE = '{cloud_name}/{initiator}/{date}/{scope}{env}{report_name}_{timestamp}.zip'

BUCKET_NAME = env_checker_utils.get_env_variable_value_by_name('ENVCHECKER_STORAGE_BUCKET')
CLOUD_NAME = env_checker_utils.get_cloud_name()

# S3 bucket expiration rule settings
EXPIRATION_DAYS = int(env_checker_utils.get_env_variable_value_by_name('ENVIRONMENT_CHECKER_STORAGE_BUCKET_EXPIRATION_DAYS'))
EXPIRATION_RULE_PREFIX = f'{CLOUD_NAME}/'
EXPIRATION_RULE = {
    'Expiration': {
        'Days': EXPIRATION_DAYS  # clean reports each EXPIRATION_DAYS days
    },
    'ID': str(uuid.uuid4()),
    'Status': 'Enabled',
    'Filter': {
        'Prefix': EXPIRATION_RULE_PREFIX    # apply rule for all files under directory, in which Env-Checker stores its reports
    }
}

S3_URL = None
S3_ACCESS_KEY = None
S3_SECRET_KEY = None
s3_client = None

def auth_call(host: str, user: str, token: str, region: str = "us-east-1") -> Result:
    try:

        s3 = boto3.client(
            "s3",
            endpoint_url=host,
            aws_access_key_id=user,
            aws_secret_access_key=token,
            config=Config(
                signature_version="s3v4",
                request_checksum_calculation='when_required',
                response_checksum_validation='when_required'),
            region_name=region,
            verify=False)

        response = s3.list_buckets()

        if response:
            return Result(ResultStatus.SUCCESS, "Successfully connected and listed buckets.")
        return Result(ResultStatus.FAIL, f"Bad response: {str(response)}", str(response), ErrorCode.ENVCH_1569.getErrorMessage())
            

    except ClientError as client_err:
        fin_msg: str = ""
        errCode: str = ""
        if client_err.response["Error"]["Code"] == "InvalidAccessKeyId":
            fin_msg = "Could not list buckets"
            errCode = ErrorCode.ENVCH_1570.getErrorMessage()
        else:
            errCode = ErrorCode.ENVCH_1569.getErrorMessage()
            fin_msg = "Error while connecting to S3"
        return Result(ResultStatus.FAIL, fin_msg, f"{client_err}\n{traceback.format_exc()}", errCode)
    
    except Exception as e:
        return Result(ResultStatus.FAIL, str(e), traceback.format_exc(), ErrorCode.ENVCH_1569.getErrorMessage())

def init_env_checker_bucket():
    global S3_URL, S3_ACCESS_KEY, S3_SECRET_KEY, s3_client
    if S3_URL is None:
        S3_URL = env_checker_utils.get_env_variable_value_by_name('STORAGE_SERVER_URL')
    if S3_ACCESS_KEY is None:
        S3_ACCESS_KEY = env_checker_utils.get_env_variable_value_by_name('STORAGE_USERNAME')
    if S3_SECRET_KEY is None:
        S3_SECRET_KEY = env_checker_utils.get_env_variable_value_by_name('STORAGE_PASSWORD')
    if s3_client is None:
        s3_client = boto3.client(
            service_name = 's3',
            endpoint_url = S3_URL,
            aws_access_key_id = S3_ACCESS_KEY,
            aws_secret_access_key = S3_SECRET_KEY,
            config = Config(
                signature_version = "s3v4",
                request_checksum_calculation = 'when_required',
                response_checksum_validation = 'when_required'),
            region_name = 'us-east-1',
            verify = False)

    # check if bucket for env-checker exists:
    try:
        s3_client.head_bucket(Bucket = BUCKET_NAME)
        verify_bucket_expiration_rule_is_set()
    except ClientError as e:
        error_code = e.response['Error']['Code']
        # if it is a 404 error, then the bucket does not exist, and we create it:
        if error_code == '404':
            s3_client.create_bucket(Bucket = BUCKET_NAME)
            put_lifecycle_config_with_expiration_rule()
        else:
            print(f'Unexpected error when trying to check S3 bucket existance: {error_code}')
            sys.exit(1)

def uploadReportsByExecutedNotebookPath(executed_notebook_path: str) -> str:
    """Gets all generated reports with name, which are related to executed notebook with path=executed_notebook_path, zips them and uploads zip to S3 storage bucket
    WARNING: must be used only for `run.sh`

    Parameters
    ----------
    executed_notebook_path : str
        path of executed notebook, which should be uploaded to S3
    execution_start_millis : int
        epoch milliseconds, indicating notebook execution start time
    initiator : str
        initiator of notebook execution

    Returns
    -------
    str
        URL to download uploaded table from bucket (auth is required)
    """

    init_env_checker_bucket()
    zip = env_checker_utils.zip_reports_by_executed_notebook_path(executed_notebook_path)
    if zip is None:
        return
    zip.seek(0)
    # take executed notebook base name, cut off timestamp
    nb_exec_data = nb_data_manipulation_utils.extract_nb_execution_data_from_result_file_for_s3_pushing(executed_notebook_path)
    if nb_exec_data is None:
        return

    s3_upload_location = format_report_path_with_nb_exec_data(nb_exec_data)
    try:
        s3_client.upload_fileobj(zip, BUCKET_NAME, s3_upload_location)
        url = REPORT_FULL_URL_TEMPLATE.format(s3_server_url = S3_URL, bucket_name = BUCKET_NAME, 
                                              bucket_to_report_path = s3_upload_location)
        print(f'{executed_notebook_path} reports are saved in S3: {url}')
    except ClientError as e:
        logging.error(e)
        return
    nb_data_manipulation_utils.update_s3_link_label_for_notebook_from_result_file(executed_notebook_path)
    return url

def convert_timestamp_to_date_str(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp = timestamp, tz = pytz.utc).strftime('%Y-%m-%d')

def format_report_path_with_nb_exec_data(nb_exec_data: dict)  -> str:
    start_timestamp_millis = nb_exec_data[constants.LAST_RUN]
    start_timestamp_seconds = int(nb_exec_data[constants.LAST_RUN] / 1000)
    scope = nb_exec_data[constants.SCOPE_LABEL]
    env = nb_exec_data[constants.ENV_LABEL]
    return REPORT_PATH_TEMPLATE.format(report_name = nb_exec_data[constants.REPORT_NAME_LABEL], initiator = nb_exec_data[constants.INITIATOR_LABEL], 
                                       date = convert_timestamp_to_date_str(start_timestamp_seconds), cloud_name = CLOUD_NAME, 
                                       scope = scope + '_' if scope != 'null' else '', 
                                       env = env + '_' if env != 'null' else '',
                                       timestamp = start_timestamp_millis)

def check_and_update_expiration_rule(bucket_lifecycle_config: dict):
    rule_already_present = False
    bucket_rules = bucket_lifecycle_config['Rules']
    for rule in bucket_rules:
        if rule['Filter']['Prefix'] == EXPIRATION_RULE_PREFIX:
            rule_already_present = True
            configured_exp_days = rule['Expiration']['Days']
            if configured_exp_days != EXPIRATION_DAYS:
                rule['Expiration']['Days'] = EXPIRATION_DAYS
                if log_level == 'DEBUG':
                    print(f'Updating S3 bucket expiration days for directory {EXPIRATION_RULE_PREFIX}: {EXPIRATION_DAYS}')
                s3_client.put_bucket_lifecycle_configuration(
                    Bucket=BUCKET_NAME,
                    LifecycleConfiguration=prepare_lifecycle_config_with_rules(bucket_rules)
                )
            break
    if not rule_already_present:
        if log_level == 'DEBUG':
            print(f'Add bucket expiration rule for S3 bucket. Expiration days for directory {EXPIRATION_RULE_PREFIX}: {EXPIRATION_DAYS}')
        bucket_rules.append(EXPIRATION_RULE)
        s3_client.put_bucket_lifecycle_configuration(
            Bucket=BUCKET_NAME,
            LifecycleConfiguration=prepare_lifecycle_config_with_rules(bucket_rules)
        )

def prepare_lifecycle_config_with_rules(rules: list):
    return {'Rules': rules}

def put_lifecycle_config_with_expiration_rule():
    s3_client.put_bucket_lifecycle_configuration(
        Bucket=BUCKET_NAME, 
        LifecycleConfiguration=prepare_lifecycle_config_with_rules([EXPIRATION_RULE])
    )

def verify_bucket_expiration_rule_is_set():
    try:
        bucket_lifecycle_config = s3_client.get_bucket_lifecycle_configuration(Bucket=BUCKET_NAME)
        check_and_update_expiration_rule(bucket_lifecycle_config)
    except ClientError:    # lifecycle configuration is not set up yet. Create and put it.
        if log_level == 'DEBUG':
            print(f'Create lifecycle configuration for bucket. Expiration days for directory {EXPIRATION_RULE_PREFIX}: {EXPIRATION_DAYS}')
        put_lifecycle_config_with_expiration_rule()
