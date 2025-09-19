import unittest
import subprocess
import os

class TestDisablingReport(unittest.TestCase):

    def test_pdf_creation(self):
        command = ['bash', '/home/jovyan/run.sh', '--pdf=false', '/home/jovyan/tests/notebooks/test_notebook.ipynb']
        subprocess.run(command, check=True)

        # check that the directory exists
        if not os.path.isdir('/home/jovyan/out'):
            self.fail("The output directory does not exist.")

        pdf_files = [f for f in os.listdir('/home/jovyan/out/') if f.endswith('.pdf')]
        self.assertEqual(len(pdf_files), 0, "PDF files generate in the 'out' directory. Flag '--pdf=false' did not work")

if __name__ == '__main__':
    unittest.main()
