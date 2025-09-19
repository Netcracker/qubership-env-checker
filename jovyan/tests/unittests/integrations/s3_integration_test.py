import unittest
import subprocess
import os
import shutil

# not ready script
class TestS3Integration(unittest.TestCase):

    def test_s3_integration(self):

        command = ['bash', "/home/jovyan/run.sh", "-r", "s3", "/home/jovyan/notebooks/tests/test_notebook.ipynb"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        if result.returncode == 1:
            self.fail(f"Error while trying to send result to s3. stdout={result.stdout}, stderr={result.stderr}")

        report_was_created_message = 'reports are saved in S3'
        if report_was_created_message not in result.stdout:
            self.fail(f"The result of sending reports to s3 does not contain information about successful sending. result={result}")

if __name__ == '__main__':
    unittest.main()
