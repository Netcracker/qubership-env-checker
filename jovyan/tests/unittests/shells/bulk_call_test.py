import unittest
import subprocess
import os

class BulkCallTest(unittest.TestCase):

    def test_bulk_call(self):

        yaml_content = """
            checks:
              - path: /home/jovyan/tests/notebooks/test_notebook.ipynb
                params:
                    bulk_check_file_name: bulk_report
              - path: /home/jovyan/tests/notebooks/test_notebook.ipynb
                params:
                    bulk_check_file_name: bulk_report
        """

        command = ['bash', '/home/jovyan/run.sh', '-o', 'bulk_check', '-y', yaml_content]
        subprocess.run(command, check=True)

        ipynb_files = [f for f in os.listdir('/home/jovyan/out/bulk_check') if f.endswith('.ipynb')]
        self.assertEqual(len(ipynb_files), 2, f"Some problem with bulk_run: Number of expected files for test = 2, AR={len(ipynb_files)}")


if __name__ == '__main__':
    unittest.main()
