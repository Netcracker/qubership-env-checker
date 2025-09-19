import unittest
import subprocess
import os

class JFlagTest(unittest.TestCase):

    def test_j_flag(self):

        command = ['bash', '/home/jovyan/run.sh', '-j', '{"checks":[{"path":"/home/jovyan/tests/notebooks/test_notebook.ipynb"}]}']
        subprocess.run(command, check=True)

        # check that the directory exists
        if not os.path.isdir('/home/jovyan/out'):
            self.fail("The output directory does not exist.")

        ipynb_files = [f for f in os.listdir('/home/jovyan/out/') if f.endswith('.ipynb')]
        self.assertGreater(len(ipynb_files), 0, "'-j' flag for run.sh works incorrectly")

if __name__ == '__main__':
    unittest.main()
