"""Shared NDJSON logger for env-checker.

Emits one JSON object per line carrying the fields the Qubership logging guide
requires (`time`, `level`, `message`), followed by whatever key/value pairs the
call site passes as keyword arguments.

Three properties of this repository shape the design.

Records go to stderr, never to stdout. `run.sh` captures the stdout of helper
processes with command substitution (`metrics=$(python -c "... print(...)")`)
and turns it into metrics and `result.yaml`, so a log record on stdout corrupts
that data channel. Those captures redirect stderr away, and Kubernetes collects
stderr as container log output just like stdout.

Inside a Jupyter kernel the logger stays silent. Notebook cell output is the
product's human-facing report, so `print()` keeps working unchanged and the
structured records are suppressed instead of surfacing as red stderr text in the
cell. Container-level processes (the check runner, the Jupyter server, and
anything started from the shell) get the JSON records.

The formatter is hand-rolled on top of the standard library, so the image needs
no new dependency. The image installs its packages with `mamba` from a pinned
condarc, where adding `python-json-logger` is not clearly safe.
"""

import json
import logging
import os
import re
import sys
import traceback
from datetime import datetime, timezone

LOGGER_NAME = "envchecker"

LEVEL_ENV_VAR = "ENVIRONMENT_CHECKER_LOG_LEVEL"
FORMAT_ENV_VAR = "ENVIRONMENT_CHECKER_LOG_FORMAT"

_ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

_OFF = logging.CRITICAL + 10

# `ENVIRONMENT_CHECKER_LOG_LEVEL` has always been a boolean in practice: every
# call site compares it against the literal 'ERROR', so 'ERROR' and an unset
# value mean "not verbose" rather than "errors only", and any other value turns
# the debug output on. This table keeps that contract — 'ERROR' and an unset
# value suppress exactly the records that were gated before, and nothing else —
# while giving OFF, FATAL, WARN and INFO a threshold of their own on top.
_LEVEL_NAMES = {
    "OFF": _OFF,
    "FATAL": logging.CRITICAL,
    "CRITICAL": logging.CRITICAL,
    "ERROR": logging.INFO,
    "WARN": logging.WARNING,
    "WARNING": logging.WARNING,
    "INFO": logging.INFO,
    "DEBUG": logging.DEBUG,
    "TRACE": logging.DEBUG,
}

_DEFAULT_LEVEL = logging.INFO

# The logging guide spells these two levels WARN and FATAL.
_LEVEL_LABELS = {"WARNING": "WARN", "CRITICAL": "FATAL"}

# Call-site fields travel on the LogRecord under this single attribute. Passing
# them as separate `extra` keys is not an option: logging.makeRecord() raises
# KeyError for any key that collides with a LogRecord attribute, so a field
# named `module`, `name` or `filename` would crash the caller.
_FIELDS_ATTR = "envchecker_fields"


def read_setting(name):
    """Read a setting the way the rest of the repository reads its settings.

    The cloud passport mount wins over the environment, matching
    `env_checker_utils.get_env_variable_value_by_name`. That helper is not
    imported here because it imports this module.
    """
    path = "/etc/cloud-passport/" + name
    try:
        if os.path.isfile(path):
            with open(path, "r") as passport_file:
                value = passport_file.read()
            if value:
                return value
    except OSError:
        pass
    return os.environ.get(name)


def strip_ansi(value):
    """Remove ANSI color escapes so they never reach a JSON value."""
    return _ANSI_ESCAPE.sub("", value) if isinstance(value, str) else value


def resolve_level(raw=None):
    """Map `ENVIRONMENT_CHECKER_LOG_LEVEL` onto a standard logging level."""
    if raw is None:
        raw = read_setting(LEVEL_ENV_VAR)
    if raw is None or not str(raw).strip():
        return _DEFAULT_LEVEL
    name = str(raw).strip().upper()
    if name in _LEVEL_NAMES:
        return _LEVEL_NAMES[name]
    # Preserve the historical contract: any value other than 'ERROR' is verbose.
    return logging.DEBUG


def resolve_format(raw=None):
    """Return 'json' (the default) or 'text' for `ENVIRONMENT_CHECKER_LOG_FORMAT`."""
    if raw is None:
        raw = read_setting(FORMAT_ENV_VAR)
    if raw is not None and str(raw).strip().lower() == "text":
        return "text"
    return "json"


def in_kernel():
    """True when this process is an IPython kernel serving notebook cells."""
    if "ipykernel" in sys.modules:
        return True
    return bool(os.environ.get("JPY_PARENT_PID") and "IPython" in sys.modules)


def _serializable(value):
    if isinstance(value, str):
        return strip_ansi(value)
    if isinstance(value, BaseException):
        return strip_ansi("%s: %s" % (type(value).__name__, value))
    if isinstance(value, bytes):
        return strip_ansi(value.decode("utf-8", "replace"))
    if isinstance(value, (bool, int, float)) or value is None:
        return value
    return strip_ansi(str(value))


def _entry(record):
    """Build the flat field mapping for one record."""
    entry = {
        "time": datetime.fromtimestamp(
            record.created, tz=timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (record.msecs,),
        "level": _LEVEL_LABELS.get(record.levelname, record.levelname),
        "message": strip_ansi(record.getMessage()),
    }
    for key, value in getattr(record, _FIELDS_ATTR, {}).items():
        value = _serializable(value)
        # Keys with empty values must not be added.
        if value is None or value == "" or value == [] or value == {}:
            continue
        entry[str(key)] = value
    if record.exc_info and "stacktrace" not in entry:
        entry["stacktrace"] = "".join(
            traceback.format_exception(*record.exc_info)
        ).rstrip()
    return entry


class NdjsonFormatter(logging.Formatter):
    """Render a LogRecord as a single line of JSON."""

    def format(self, record):
        # `json.dumps` escapes newlines and tabs, so the result is one line.
        return json.dumps(_entry(record), default=str, ensure_ascii=False)


class QubershipTextFormatter(logging.Formatter):
    """Render a LogRecord in the legacy Qubership text format, on one line."""

    def format(self, record):
        entry = _entry(record)
        head = "[%s] [%s]" % (entry.pop("time"), entry.pop("level"))
        message = entry.pop("message")
        pairs = "".join(" [%s=%s]" % (key, value) for key, value in entry.items())
        return ("%s%s %s" % (head, pairs, message)).replace("\n", "\\n")


def make_formatter():
    """Return the formatter selected by `ENVIRONMENT_CHECKER_LOG_FORMAT`."""
    if resolve_format() == "text":
        return QubershipTextFormatter()
    return NdjsonFormatter()


def _base_logger():
    logger = logging.getLogger(LOGGER_NAME)
    if not logger.handlers:
        if in_kernel():
            logger.addHandler(logging.NullHandler())
            logger.disabled = True
        else:
            handler = logging.StreamHandler(sys.stderr)
            handler.setFormatter(make_formatter())
            logger.addHandler(handler)
        logger.setLevel(resolve_level())
        logger.propagate = False
    return logger


class StructuredLogger(object):
    """Thin adapter that turns keyword arguments into structured JSON fields.

    `log.info("Connection check succeeded", url=url)` emits
    `{"time": ..., "level": "INFO", "message": "Connection check succeeded",
    "url": ...}`.
    """

    def __init__(self, name):
        self._logger = _base_logger()
        self._name = name

    def _emit(self, level, message, exc_info=False, **fields):
        if not self._logger.isEnabledFor(level):
            return
        fields.setdefault("logger", self._name)
        self._logger.log(
            level, message, exc_info=exc_info, extra={_FIELDS_ATTR: fields})

    def debug(self, message, **fields):
        self._emit(logging.DEBUG, message, **fields)

    def info(self, message, **fields):
        self._emit(logging.INFO, message, **fields)

    def warning(self, message, **fields):
        self._emit(logging.WARNING, message, **fields)

    warn = warning

    def error(self, message, **fields):
        self._emit(logging.ERROR, message, **fields)

    def exception(self, message, **fields):
        self._emit(logging.ERROR, message, exc_info=True, **fields)

    def critical(self, message, **fields):
        self._emit(logging.CRITICAL, message, **fields)

    fatal = critical


def get_logger(name=None):
    """Return the structured logger for a module."""
    return StructuredLogger(name or LOGGER_NAME)


def logging_config(*logger_names):
    """Build a `logging.config.dictConfig` payload for the given loggers.

    `installation/python/jupyter_server_config.py` feeds the result to
    `c.Application.logging_config`, so the Jupyter server and Tornado emit the
    same records as the check runner.
    """
    level = logging.getLevelName(resolve_level())
    formatter = {
        "()": "structured_log.NdjsonFormatter"
        if resolve_format() == "json"
        else "structured_log.QubershipTextFormatter"
    }
    return {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {"envchecker": formatter},
        "handlers": {
            "envchecker": {
                "class": "logging.StreamHandler",
                "formatter": "envchecker",
                "stream": "ext://sys.stderr",
            }
        },
        "loggers": {
            name: {"handlers": ["envchecker"], "level": level, "propagate": False}
            for name in logger_names
        },
    }


def install_on(*logger_names):
    """Route third-party loggers (ServerApp, tornado, ...) through the formatter.

    traitlets installs its own handler after the configuration file is read, so
    this runs as a second pass over the loggers `logging_config` already covers.
    """
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(make_formatter())
    level = resolve_level()
    for name in logger_names:
        logger = logging.getLogger(name)
        for existing in list(logger.handlers):
            logger.removeHandler(existing)
        logger.addHandler(handler)
        logger.setLevel(level)
        logger.propagate = False
    return handler
