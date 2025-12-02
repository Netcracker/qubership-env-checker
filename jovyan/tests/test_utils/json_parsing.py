import json
import os


class JsonReport:

    def __init__(self):
        self.checks = []
        self.overall_result = "Passed"

    def add_check(
        self, name, status, description="", error_description="",
        time_exec=""
    ):
        check = {
            "name": name,
            "status": status,
            "description": description,
            "error_description": error_description,
            "time_exec": time_exec
        }
        self.checks.append(check)
        self.update_overall_result()
        return self.checks

    def add_check_with_existing_json(
        self,
        existing_json,
        name,
        status,
        description="",
        error_description="",
        time_exec=""
    ):
        if existing_json:
            self.checks = existing_json.get("checks", [])
            self.overall_result = existing_json.get("overall_result", "Passed")

        check = {
            "name": name,
            "status": status,
            "description": description,
            "error_description": error_description,
            "time_exec": time_exec
        }
        self.checks.append(check)
        self.update_overall_result()
        return self.checks

    def update_overall_result(self):
        if any(check["status"] == "Failed" for check in self.checks):
            self.overall_result = "Failed"
        else:
            self.overall_result = "Passed"

    @staticmethod
    def save_to_file(json_data, file_path, file_name):
        full_path = os.path.join(file_path, file_name)
        os.makedirs(file_path, exist_ok=True)
        with open(full_path, 'w') as f:
            json.dump(json_data, f, indent=4)
        return full_path
