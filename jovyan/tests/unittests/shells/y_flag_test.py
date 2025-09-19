import unittest
import subprocess
import os
import yaml
import json

class YFlagTest(unittest.TestCase):

    def test_y_flag(self):

        yaml_string = """
        checks:
          - path: /home/jovyan/tests/notebooks/test_notebook.ipynb
            params:
              report_name: k8sapps10_report
        """

        yaml_dict = yaml.safe_load(yaml_string)
        json_string = json.dumps(yaml_dict)
        command = ['bash', '/home/jovyan/run.sh', '-j', json_string]
        subprocess.run(command, check=True)

        # check that the directory exists
        if not os.path.isdir('/home/jovyan/out'):
            self.fail("The output directory does not exist.")

        ipynb_files = [f for f in os.listdir('/home/jovyan/out/') if f.endswith('.ipynb')]
        self.assertGreater(len(ipynb_files), 0, "'-y' flag for run.sh works incorrectly")

if __name__ == '__main__':
    unittest.main()
