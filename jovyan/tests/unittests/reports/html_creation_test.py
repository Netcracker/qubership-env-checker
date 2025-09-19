import unittest
import subprocess
import os

class TestHtmlReport(unittest.TestCase):

    def test_html_creation(self):
        command = ['bash', '/home/jovyan/run.sh', '--html=true', '/home/jovyan/tests/notebooks/test_notebook.ipynb']
        subprocess.run(command, check=True)

        # check that the directory exists
        if not os.path.isdir('/home/jovyan/out'):
            self.fail("The output directory does not exist.")

        html_files = [f for f in os.listdir('/home/jovyan/out/') if f.endswith('.html')]
        self.assertGreater(len(html_files), 0, "HTML files did not generate in the 'out' directory. Flag '--html=true' did not work")

if __name__ == '__main__':
    unittest.main()
