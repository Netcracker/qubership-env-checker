import sys
sys.path
sys.path.append("/home/jovyan/utils")
import math
import urllib3
import env_checker_utils
import nb_data_manipulation_utils
import constants

from NotebookMetrics import NotebookMetrics
from urllib.parse import urljoin
from typing import Dict
from opentelemetry import metrics as metricsLib
from opentelemetry.exporter.prometheus_remote_write import (
    PrometheusRemoteWriteMetricsExporter,
)
from opentelemetry.sdk.metrics import MeterProvider, ObservableGauge
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource

ENVHECKER_SOLUTION_CORRECTNESS_STATUS = 'envchecker_solution_correctness_status'
ENVHECKER_SOLUTION_CORRECTNESS_LAST_RUN = 'envchecker_solution_correctness_last_run'
ENVHECKER_SOLUTION_CORRECTNESS_LAST_DURATION = 'envchecker_solution_correctness_last_duration'


class Metric:
    def __init__(self, name: str, value: int, labels: dict):
        self.name = name
        self.value = value
        self.labels = labels

    def get_name(self):
        return self.name

    def get_value(self):
        return self.value

    def set_value(self, value):
        self.value = value

    def get_labels(self):
        return self.labels

    def set_labels(self, labels):
        self.labels = labels
    
    
class MonitoringHelper:
    MONITORING_URL = env_checker_utils.get_env_variable_value_by_name('MONITORING_URL')
    if MONITORING_URL is None:
        print(f'Cannot determine URL of monitoring system.')
        sys.exit(1)
    MONITORING_USER = env_checker_utils.get_env_variable_value_by_name('MONITORING_USER')
    if MONITORING_USER is None:
        MONITORING_USER = ''
    MONITORING_PASSWORD = env_checker_utils.get_env_variable_value_by_name('MONITORING_PASSWORD')
    if MONITORING_PASSWORD is None:
        MONITORING_PASSWORD = ''
    S3_URL = env_checker_utils.get_env_variable_value_by_name('STORAGE_SERVER_URL')
    

    exporter = PrometheusRemoteWriteMetricsExporter(
        endpoint=urljoin(MONITORING_URL, '/api/v1/write'),
        basic_auth={
            'username': MONITORING_USER,
            'password': MONITORING_PASSWORD,
        },
        tls_config={'insecure_skip_verify': False}
    )

    reader = PeriodicExportingMetricReader(exporter, math.inf)
    provider = MeterProvider(metric_readers=[reader], resource=Resource({}))
    metricsLib.set_meter_provider(provider)
    meter = metricsLib.get_meter('meter')
    
    status_metrics = []
    last_run_metrics = []
    last_duration_metrics = []

    urllib3.disable_warnings()

    @classmethod
    def registerGauges(cls):
        """
        Registers (if not registered already) 3 ObservableGauge instruments for representing ENVHECKER_SOLUTION_CORRECTNESS_STATUS,
        ENVHECKER_SOLUTION_CORRECTNESS_LAST_RUN, ENVHECKER_SOLUTION_CORRECTNESS_LAST_DURATION metrics.
        Each ObservableGauge will be used then to create metrics in monitoring. 
        """

        if not cls.meter._is_instrument_registered(name=ENVHECKER_SOLUTION_CORRECTNESS_STATUS, type_=type(ObservableGauge), unit='', description='')[0]:
            def status_observable_gauge_func(options):
                observations = []
                for m in cls.status_metrics:
                    observations.append(metricsLib.Observation(m.get_value(), m.get_labels()))
                return observations
            cls.meter.create_observable_gauge(ENVHECKER_SOLUTION_CORRECTNESS_STATUS, [status_observable_gauge_func])

        if not cls.meter._is_instrument_registered(name=ENVHECKER_SOLUTION_CORRECTNESS_LAST_RUN, type_=type(ObservableGauge), unit='', description='')[0]:
            def last_run_observable_gauge_func(options):
                observations = []
                for m in cls.last_run_metrics:
                    observations.append(metricsLib.Observation(m.get_value(), m.get_labels()))
                return observations
            cls.meter.create_observable_gauge(ENVHECKER_SOLUTION_CORRECTNESS_LAST_RUN, [last_run_observable_gauge_func])

        if not cls.meter._is_instrument_registered(name=ENVHECKER_SOLUTION_CORRECTNESS_LAST_DURATION, type_=type(ObservableGauge), unit='', description='')[0]:
            def last_duration_observable_gauge_func(options):
                observations = []
                for m in cls.last_duration_metrics:
                    observations.append(metricsLib.Observation(m.get_value(), m.get_labels()))
                return observations
            cls.meter.create_observable_gauge(ENVHECKER_SOLUTION_CORRECTNESS_LAST_DURATION, [last_duration_observable_gauge_func])

    @classmethod
    def flush(cls):
        """
        Forces exporter to push data, provided by registered ObservableGauge instances, to monitoring.
        """        

        cls.reader.collect(1000)    
        cls.exporter.force_flush(1000)

    @classmethod
    def pushNotebookExecutionResultsToMonitoringByExecutedNotebookPath(cls, executed_notebook_path: str):
        """
        WARNING: must be used only by run.sh
        """        

        notebook_execution_data_list = nb_data_manipulation_utils.extract_notebook_execution_data_from_result_file(executed_notebook_path)
        cls.pushToMonitoring(notebook_execution_data_list)

    @classmethod
    def pushToMonitoring(cls, notebook_metrics: list[NotebookMetrics]):
        cls.status_metrics = []
        cls.last_run_metrics = []
        cls.last_duration_metrics = []
        
        for notebook_metric in notebook_metrics:
            last_duration = notebook_metric.get_last_duration()
            last_run = notebook_metric.get_last_run()
            status = notebook_metric.get_status()
            labels = {
                constants.INITIATOR_LABEL: notebook_metric.get_initiator(), 
                constants.REPORT_NAME_LABEL: notebook_metric.get_report_name(), 
                constants.S3_LINK_LABEL: notebook_metric.get_s3_link(),
                constants.REPORT_NAMESPACE_LABEL: notebook_metric.get_report_namespace(),
                constants.REPORT_APP_LABEL: notebook_metric.get_report_app(),
                constants.ENV_LABEL: notebook_metric.get_env(),
                constants.SCOPE_LABEL: notebook_metric.get_scope()
            }
            
            cls.status_metrics.append(Metric(ENVHECKER_SOLUTION_CORRECTNESS_STATUS, status, labels))
            cls.last_run_metrics.append(Metric(ENVHECKER_SOLUTION_CORRECTNESS_LAST_RUN, last_run, labels))
            cls.last_duration_metrics.append(Metric(ENVHECKER_SOLUTION_CORRECTNESS_LAST_DURATION, last_duration, labels))

        cls.registerGauges()             
        cls.flush()