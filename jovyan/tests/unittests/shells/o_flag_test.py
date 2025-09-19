import unittest
import subprocess
import os

class OFlagTest(unittest.TestCase):

    def test_o_flag(self):

        command = ['bash', '/home/jovyan/run.sh', '-o', 'test1', '/home/jovyan/tests/notebooks/test_notebook.ipynb']
        subprocess.run(command, check=True)

        # check that the directory exists
        if not os.path.isdir('/home/jovyan/out/test1'):
            self.fail("The test1 directory does not exist.")

        ipynb_files = [f for f in os.listdir('/home/jovyan/out/test1') if f.endswith('.ipynb')]
        self.assertGreater(len(ipynb_files), 0, "'-o' flag for run.sh works incorrectly")

if __name__ == '__main__':
    unittest.main()
