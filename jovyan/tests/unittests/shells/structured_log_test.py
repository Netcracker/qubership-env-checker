import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[4]
UTILS = ROOT / 'jovyan' / 'utils'
JUPYTER_CONFIG = ROOT / 'installation/python/jupyter_server_config.py'
if not JUPYTER_CONFIG.exists():
    JUPYTER_CONFIG = Path('/etc/jupyter/jupyter_server_config.py')
START_SCRIPT = ROOT / 'installation/shells/start.sh'
if not START_SCRIPT.exists():
    START_SCRIPT = Path('/usr/local/bin/start.sh')


class StructuredLogTest(unittest.TestCase):
    def run_python(self, code, **settings):
        result = subprocess.run(
            [sys.executable, '-c', code], capture_output=True,
            text=True, env={**os.environ, 'PYTHONPATH': str(UTILS), **settings})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_json_escapes_multiline_messages_and_exception(self):
        result = self.run_python('''
import structured_log
log = structured_log.get_logger('test')
try:
    raise ValueError('first\\nsecond\\t\\x01')
except ValueError:
    log.exception('message\\n"quoted"\\t\\x01', module='caller', empty='')
print('data')
''')
        self.assertEqual(result.stdout, 'data\n')
        records = result.stderr.splitlines()
        self.assertEqual(len(records), 1)
        record = json.loads(records[0])
        self.assertEqual(record['message'], 'message\n"quoted"\t\x01')
        self.assertEqual(record['module'], 'caller')
        self.assertNotIn('empty', record)
        self.assertIn('ValueError: first\nsecond', record['stacktrace'])

    def test_off_dict_config_suppresses_every_standard_level(self):
        result = self.run_python('''
import logging.config
import structured_log
logging.config.dictConfig(structured_log.logging_config('ServerApp'))
log = logging.getLogger('ServerApp')
log.setLevel(logging.DEBUG)
for level in (10, 20, 30, 40, 50):
    log.log(level, 'must stay silent')
structured_log.get_logger().critical('must stay silent')
''', ENVIRONMENT_CHECKER_LOG_LEVEL='OFF')
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def test_jupyter_off_uses_an_accepted_traitlets_level(self):
        result = self.run_python(f'''
import runpy
from traitlets.config import Config
from jupyter_server.serverapp import ServerApp
config = Config()
runpy.run_path({str(JUPYTER_CONFIG)!r},
               init_globals={{'get_config': lambda: config}})
app = ServerApp(config=config)
app.log.critical('must stay silent')
''', ENVIRONMENT_CHECKER_LOG_LEVEL='OFF')
        self.assertEqual(result.stderr, '')

    def test_text_format_keeps_data_on_stdout(self):
        result = self.run_python('''
import structured_log
structured_log.get_logger().warning('first\\nsecond')
print('data')
''', ENVIRONMENT_CHECKER_LOG_FORMAT='text')
        self.assertEqual(result.stdout, 'data\n')
        self.assertIn('[WARN]', result.stderr)
        self.assertIn('first\\nsecond', result.stderr)
        self.assertEqual(len(result.stderr.splitlines()), 1)

    def test_parse_out_keeps_notebook_result_on_stdout(self):
        notebook = {'cells': [{'metadata': {'tags': ['result']}, 'outputs': [
            {'data': {'text/plain': ['True']}}]}]}
        result = subprocess.run(
            [sys.executable, str(UTILS / 'parseOut.py')],
            input=json.dumps(notebook), text=True, capture_output=True,
            check=True)
        self.assertEqual(result.stdout, 'True\n')
        self.assertEqual(result.stderr, '')

    def test_git_failure_is_json_and_redacts_url_credentials(self):
        result = self.run_python('''
from integration import git_helper
from unittest.mock import patch
import subprocess
url = 'https://user:secret@invalid.example/repo.git'
error = subprocess.CalledProcessError(1, ['git', 'remote', 'add', url])
with patch.object(git_helper, 'fetch_from_repo', side_effect=error):
    assert not git_helper.run_fetch(url, '/tmp/unused', '')
''')
        self.assertEqual(result.stdout, '')
        record = json.loads(result.stderr)
        self.assertEqual(record['level'], 'ERROR')
        self.assertNotIn('secret', result.stderr)
        self.assertNotIn('user:', result.stderr)

    def test_git_progress_redacts_url_credentials(self):
        result = self.run_python('''
from integration import git_helper
from unittest.mock import patch
with patch.object(git_helper.os.path, 'exists', side_effect=RuntimeError('stop')):
    git_helper.run_fetch('https://user:secret@invalid.example/repo.git',
                         '/tmp/unused', '')
''')
        self.assertNotIn('secret', result.stderr)
        for line in result.stderr.splitlines():
            json.loads(line)

    def test_shell_git_progress_does_not_expose_url_credentials(self):
        result = subprocess.run(
            ['bash', '-c', 'source "$1" "$2"; '
             'prepare_git_config_files() { :; }; '
             'check_relative_path_is_exists() { :; }; gitProcess',
             'test', str(ROOT / 'jovyan/shells/git_helper.sh'),
             'https://user:secret@invalid.example/repo.git'],
            capture_output=True, text=True, check=True)
        self.assertNotIn('secret', result.stderr)
        self.assertEqual(result.stdout, 'repo\n')

    def test_command_output_is_json_and_preserves_failure_status(self):
        result = subprocess.run(
            ['bash', '-c', 'source "$1"; log_command bash -c '
             '\'printf "first\\nsecond\\n"; printf "error\\n" >&2; exit 7\'',
             'test', str(ROOT / 'jovyan/shells/log_json.sh')],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout, '')
        records = [json.loads(line) for line in result.stderr.splitlines()]
        self.assertEqual([r['message'] for r in records[:3]],
                         ['first', 'second', 'error'])
        self.assertEqual(records[-1]['level'], 'ERROR')
        self.assertEqual(records[-1]['exit_code'], '7')

    def test_jupyter_extension_logs_are_json_and_hide_access_tokens(self):
        result = self.run_python(f'''
import runpy
from jupyterlab.labapp import LabApp
from notebook.app import JupyterNotebookApp
from traitlets.config import Config
config = Config()
runpy.run_path({str(JUPYTER_CONFIG)!r},
               init_globals={{'get_config': lambda: config}})
for app_class in (LabApp, JupyterNotebookApp):
    app = app_class(config=config)
    app.log.warning('http://localhost/lab?token=access-secret')
''')
        self.assertNotIn('access-secret', result.stderr)
        records = [json.loads(line) for line in result.stderr.splitlines()]
        self.assertEqual(len(records), 2)
        self.assertEqual([r['level'] for r in records], ['WARN', 'WARN'])

    def test_real_git_fetch_preserves_the_data_channel(self):
        result = self.run_python('''
from pathlib import Path
import subprocess
import tempfile
from integration import git_helper
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'source'
    source.mkdir()
    (source / 'checks').mkdir()
    (source / 'checks/example.txt').write_text('notebook fixture')
    for command in (
        ['git', 'init', '-b', 'main'],
        ['git', 'add', '.'],
        ['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
         'commit', '-m', 'fixture'],
    ):
        subprocess.run(command, cwd=source, check=True, capture_output=True)
    target = Path(tmp) / 'target'
    assert git_helper.run_fetch(str(source), str(target), 'checks')
    assert (target / 'example.txt').read_text() == 'notebook fixture'
''')
        self.assertEqual(result.stdout, '')
        records = [json.loads(line) for line in result.stderr.splitlines()]
        self.assertEqual(records[0]['message'], 'Fetching the Git repository')

    def test_startup_unset_message_is_json_and_clears_the_variable(self):
        source = START_SCRIPT.read_text()
        functions = []
        for name in ('_log', 'unset_explicit_env_vars'):
            start = source.index(name + '() {')
            end = source.index('\n}\n', start) + 3
            functions.append(source[start:end])
        code = ('source "$1"; ' + '\n'.join(functions)
                + '\nunset_explicit_env_vars; '
                  'test -z "${REVIEW_UNSET+x}" && printf "data\\n"')
        result = subprocess.run(
            ['bash', '-c', code, 'test',
             str(ROOT / 'jovyan/shells/log_json.sh')],
            capture_output=True, text=True, check=True,
            env={**os.environ, 'REVIEW_UNSET': 'private-unset-value',
                 'JUPYTER_ENV_VARS_TO_UNSET': 'REVIEW_UNSET',
                 'JUPYTER_DOCKER_STACKS_QUIET': '',
                 'ENVIRONMENT_CHECKER_LOG_LEVEL': 'INFO'})
        self.assertEqual(result.stdout, 'data\n')
        record = json.loads(result.stderr)
        self.assertIn('REVIEW_UNSET', record['message'])
        self.assertNotIn('private-unset-value', result.stderr)

    def test_expired_output_cleanup_keeps_stdout_for_data(self):
        script = (ROOT / 'jovyan/shells/remove_out_catalogs.sh').read_text()
        script = script.replace('out_dir="/home/jovyan/out"', 'out_dir="$1"')
        with tempfile.TemporaryDirectory() as tmp:
            expired = Path(tmp) / 'expired'
            expired.mkdir()
            (expired / 'report.txt').write_text('expired report')
            old_time = time.time() - 7200
            os.utime(expired, (old_time, old_time))
            fresh = Path(tmp) / 'fresh'
            fresh.mkdir()
            code = ('source "$2"; eval "$3"; printf "data\\n"')
            result = subprocess.run(
                ['bash', '-c', code, 'test', tmp,
                 str(ROOT / 'jovyan/shells/log_json.sh'), script],
                capture_output=True, text=True, check=True,
                env={**os.environ, 'ENVIRONMENT_CHECKER_LOG_LEVEL': 'INFO'})
            self.assertFalse(expired.exists())
            self.assertTrue(fresh.is_dir())
        self.assertEqual(result.stdout, 'data\n')
        record = json.loads(result.stderr)
        self.assertEqual(record['folder'], str(expired))
        self.assertEqual(record['level'], 'INFO')

    def run_certificate_config(self, mode):
        code = 'mode = %r\nconfig_path = %r\n' % (mode, str(JUPYTER_CONFIG))
        code += """
import os, pathlib, runpy, stat, subprocess, sys, tempfile, types
with tempfile.TemporaryDirectory() as tmp:
    pathlib.Path(tmp, 'ssl').mkdir()
    os.environ.update(GEN_CERT='1', CONDA_DIR=tmp, ENVIRONMENT_CHECKER_LOG_LEVEL='INFO')
    if mode == 'failure':
        os.environ['OPENSSL_CONF'] = str(pathlib.Path(tmp, 'missing.cnf'))
    paths = types.ModuleType('jupyter_core.paths')
    paths.jupyter_data_dir = lambda: tmp
    sys.modules['jupyter_core'] = types.ModuleType('jupyter_core')
    sys.modules['jupyter_core.paths'] = paths
    config = types.SimpleNamespace(**{name: types.SimpleNamespace() for name in
        ('ServerApp', 'Application', 'ExtensionApp', 'InlineBackend', 'FileContentsManager')})
    try:
        runpy.run_path(config_path, init_globals={'get_config': lambda: config})
    except subprocess.CalledProcessError as error:
        assert mode == 'failure', error
        assert error.returncode != 0
    else:
        assert mode == 'success'
        pem = pathlib.Path(config.ServerApp.certfile)
        assert stat.S_IMODE(pem.stat().st_mode) == 0o600
        subprocess.run(['openssl', 'x509', '-in', str(pem), '-noout', '-checkend', '0'],
                       check=True, capture_output=True)
    print('data')
"""
        return self.run_python(code)

    def test_certificate_generation_captures_openssl_progress_as_json(self):
        result = self.run_certificate_config('success')
        self.assertEqual(result.stdout, 'data\n')
        record = json.loads(result.stderr)
        self.assertEqual(record['level'], 'INFO')
        self.assertEqual(record['message'], 'Self-signed certificate generated')
        self.assertTrue(record['certificate_path'].endswith('/notebook.pem'))
        self.assertNotIn('PRIVATE KEY', result.stderr)

    def test_certificate_generation_failure_is_json_and_still_raises(self):
        result = self.run_certificate_config('failure')
        self.assertEqual(result.stdout, 'data\n')
        record = json.loads(result.stderr)
        self.assertEqual(record['level'], 'ERROR')
        self.assertEqual(record['message'], 'Failed to generate self-signed certificate')
        self.assertNotEqual(record['exit_code'], 0)
        self.assertIn('missing.cnf', record['stderr'])

    def test_shell_json_escaping_and_off(self):
        script = str(ROOT / 'jovyan/shells/log_json.sh')
        code = 'source "$1"; log_warn "$2" field "$2"; printf "data\\n"'
        message = 'first\n"quoted"\t\r\x01\\end'
        result = subprocess.run(
            ['bash', '-c', code, 'test', script, message],
            capture_output=True, text=True, check=True,
            env={**os.environ, 'ENVIRONMENT_CHECKER_LOG_LEVEL': 'INFO'})
        self.assertEqual(result.stdout, 'data\n')
        record = json.loads(result.stderr)
        self.assertEqual(record['level'], 'WARN')
        self.assertEqual(record['message'], message.replace('\x01', ''))
        self.assertEqual(record['field'], record['message'])
        result = subprocess.run(
            ['bash', '-c', code, 'test', script, message],
            capture_output=True, text=True, check=True,
            env={**os.environ, 'ENVIRONMENT_CHECKER_LOG_LEVEL': 'OFF'})
        self.assertEqual(result.stdout, 'data\n')
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
