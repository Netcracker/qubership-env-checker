import unittest
import subprocess
import os
import shutil

# not ready test script. Integration is not developed
class TestGitIntegration(unittest.TestCase):

    def test_git_integration(self):
        version_git_link = ""  # git repository where the schema is located
        branch = ""                     # git branch where the schema is located
        yaml_schema_path = "docs"  # name and path of .yaml schema version (relative to the git root)
        output_folder = "/home/jovyan/git_source/test" # local folder where the schema from Git will be saved

        command = ['bash', "/home/jovyan/shells/git_helper.sh", "download_folder_or_file", version_git_link, branch, yaml_schema_path, output_folder]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode == 1:
            self.fail(f"Error while trying to get file from git. stdout={result.stdout}, stderr={result.stderr}")

        if not os.path.isdir(output_folder):
            self.fail(f"The {output_folder} directory does not exist.")

        yaml_schema = [f for f in os.listdir(output_folder) if f == (yaml_schema_path)]
        self.assertEqual(len(yaml_schema), 1, f"{yaml_schema_path} file does not exists in directory {output_folder}")

        try:
            shutil.rmtree("/home/jovyan/git_source")
        except OSError as e:
            self.fail(f"Error when deleting directory: {e.filename} - {e.strerror}.")

if __name__ == '__main__':
    unittest.main()
