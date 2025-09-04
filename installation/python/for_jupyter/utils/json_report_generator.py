#!/opt/conda/bin/python
import scrapbook as sb
import sys
import json
import os
import pandas as pd


def generate_report_table(report):
    data = report["values"]
    if data:
        df = pd.DataFrame(data)
        for index, row in df.iterrows():
            checks = row.get("checks", {})
            for key, value in checks.items():
                new_column_name = f"{key}"
                df.at[index, new_column_name] = value
        df = df.drop(columns=["checks"])
        return df
    else:
        print("No data to generate")
        data = {'Value': ['No data']}
        return pd.DataFrame(data)


def process_notebook_file(notebook_files, reports):
    for notebook in notebook_files:
        nb = sb.read_notebook(notebook)
        if "report" in nb.scraps.data_dict:
            report_name = nb.scraps.data_dict["report"]['name']
            if report_name not in hashes:
                hashes[report_name] = {}

            hash_code = hash(tuple(
                sorted(map(str.lower, generate_report_table(
                    nb.scraps.data_dict["report"]).columns))))

            if hash_code not in hashes[report_name]:
                hashes[report_name][hash_code] = set()
            hashes[report_name][hash_code].add(notebook)

            if report_name not in reports:
                reports[report_name] = {hash_code: generate_report_table(
                    nb.scraps.data_dict["report"])}
            else:
                if hash_code in reports[report_name]:
                    reports[report_name][hash_code] = pd.concat(
                        [reports[report_name][hash_code],
                         generate_report_table(nb.scraps.data_dict["report"])],
                        ignore_index=True)
                else:
                    reports[report_name][hash_code] = generate_report_table(
                        nb.scraps.data_dict["report"])

    for report_name, hashes_data in reports.items():
        report_entries = []
        for hash_code, df in hashes_data.items():
            rows = [row.to_dict() for _, row in df.iterrows()]
            report_entries.append({
                "notebook": list(hashes[report_name][hash_code]),
                "data": rows
            })

        output_dir = os.path.dirname(notebook_files[0])
        output_file = os.path.join(output_dir, f"{report_name}.json")
        with open(output_file, "w") as file:
            json.dump({report_name: report_entries}, file, indent=4)
        print(f"JSON report saved to {output_file}")


directory_path = sys.argv[1]
for root, _, files in os.walk(directory_path):
    reports = {}
    hashes = {}
    notebooks = []
    if os.path.basename(root).startswith('.'):
        continue
    for file in files:
        if file.endswith('.ipynb'):
            notebooks.append(os.path.join(root, file))
    process_notebook_file(notebooks, reports)

print("All reports generated")