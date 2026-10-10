import json
import jsonschema
import sys
import structured_log

from jsonschema import validate

log = structured_log.get_logger('json_schema_validation')

APP_METRICS_SCHEMA = {
    "type": "array",
    "items": {
        "type": "object",
        "properties": {
            "initiator": {"type": "string"},
            "last_run": {
                "$comment": "Amount of unix epoch milliseconds, indicating time when first (!) " +
                "check in notebook was started. " +
                "This time is supposed to be same (!) for all applications (namespaces), " +
                "which are checked in notebook.",
                "type": "number",
                "minimum": 0,
                "maximum": 2147483647000
            },
            "last_duration": {
                "$comment": "Amount of milliseconds, indicating duration of application (namespace) check execution.",
                "type": "number",
                "minimum": 0
            },
            "status": {
                "$comment": "Binary application (namespace) check execution status: 0 - success, 1 - fail.",
                "type": "number",
                "minimum": 0,
                "maximum": 1
            },
            "report_namespace": {"type": "string"},
            "report_app": {"type": "string"},
            "scope": {"type": "string"},
            "env": {"type": "string"}
        },
        "required": ["report_namespace", "status"]
    }
}


def validate_app_metrics_schema_as_dict(metrics: dict) -> bool:
    try:
        validate(instance=metrics, schema=APP_METRICS_SCHEMA)
    except jsonschema.exceptions.ValidationError as e:
        log.warning('Metrics do not match the JSON schema', error=e,
                    schema='APP_METRICS_SCHEMA')
        return False
    print(0)
    return True


def validate_app_metrics_schema(metrics_json: str) -> bool:
    metrics = {}
    try:
        metrics = json.loads(metrics_json)
    except TypeError as e:
        log.error('Metrics must be a JSON string', error=e,
                  received_type=type(metrics_json).__name__)
        sys.exit(1)
    except json.JSONDecodeError as e:
        log.error('Cannot deserialize the metrics JSON string', error=e)
        sys.exit(1)
    return validate_app_metrics_schema_as_dict(metrics)
