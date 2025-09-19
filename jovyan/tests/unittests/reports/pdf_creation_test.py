import unittest
import subprocess
import os

class TestPdfReport(unittest.TestCase):

    def test_pdf_creation(self):
        command = ['bash', '/home/jovyan/run.sh', '/home/jovyan/tests/notebooks/test_notebook.ipynb']
        subprocess.run(command, check=True)

        # check that the directory exists
        if not os.path.isdir('/home/jovyan/out'):
            self.fail("The output directory does not exist.")

        # check that at least one .pdf file appears in the /home/jovyan/out/ folder
        pdf_files = [f for f in os.listdir('/home/jovyan/out') if f.endswith('.pdf')]
        self.assertGreater(len(pdf_files), 0, "No PDF files were generated in the output directory.")

if __name__ == '__main__':
    unittest.main()
