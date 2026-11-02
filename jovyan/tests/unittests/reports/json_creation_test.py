import json
from pathlib import Path
import subprocess
import unittest


class TestJsonReport(unittest.TestCase):
    def test_json_report_is_generated_by_the_runner(self):
        result = subprocess.run(
            ['bash', '/home/jovyan/run.sh', '-r', 'json',
             '/home/jovyan/tests/notebooks/test_notebook.ipynb'],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'True\n')
        report = Path('/home/jovyan/out/FullChecksReport.json')
        self.assertTrue(report.is_file(), 'The JSON report was not generated')
        self.assertIn('FullChecksReport', json.loads(report.read_text()))
        for line in result.stderr.splitlines():
            json.loads(line)


if __name__ == '__main__':
    unittest.main()
