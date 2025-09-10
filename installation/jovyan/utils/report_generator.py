#!/opt/conda/bin/python
import os
import pandas as pd
import scrapbook as sb
from bs4 import BeautifulSoup
import sys
style = """
<style>
.tooltip { position: relative }
.tooltip .tooltiptext { visibility: hidden; position: absolute; text-align: center; background-color: Black; color: White; z-index: 1; bottom: 100%; }
.tooltip:hover .tooltiptext { visibility: visible; }
table, th, td { border:1px solid black; text-align: center }
</style> """


def generate_report_table(report):
    global flag
    data = report["values"]
    if data != []:
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


def add_style_block(html):
    global style
    html = html + style
    soup = BeautifulSoup(html, 'html.parser')

    td_tags = soup.find_all('td')

    for td in td_tags:
        if len(td.text.split()) != 0:
            if td.text.split()[0].lower() in ['ok', 'good', 'passed']:
                td['style'] = 'background-color: DarkSeaGreen;'
            if td.text.split()[0].lower() in ['error', 'failed']:
                td['style'] = 'background-color: DarkSalmon;'
            if td.text.split()[0] == 'NONE':
                td['style'] = 'background-color: LightGrey;'
    return soup.prettify()


def add_br_after_error_none_ok(text):
    words = str(text).split()
    for i, word in enumerate(words):
        if word.lower() in ['error', 'none', 'ok', 'failed', 'passed']:
            words[i] += '<br>'
            break
    return ' '.join(words)


def process_notebook_file(notebook_files, reports):
    report_file = {}
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
            if nb.scraps.data_dict["report"]["isExceptionOccured"]:
                hashes[report_name][hash_code].add(notebook + " <p style=\"display:inline;color:red;font-size:20px;\">Timeout Exception</p> ")
            else:
                hashes[report_name][hash_code].add(notebook)
            if report_name not in reports:
                reports[report_name] = {hash_code: generate_report_table(
                    nb.scraps.data_dict["report"])}
            else:
                if hash_code in reports[report_name]:
                    reports[report_name][hash_code] = pd.concat(
                        [reports[report_name][hash_code],
                         generate_report_table(
                             nb.scraps.data_dict[
                                 "report"])],
                        ignore_index=True)
                else:
                    reports[report_name][hash_code] = generate_report_table(
                        nb.scraps.data_dict["report"])
            output_dir = os.path.dirname(notebook)
            output_file = os.path.join(output_dir, f'{report_name}.html')
            report_file[report_name] = output_file

    for report, dir in report_file.items():
        with open(dir, 'a') as file:
            datas = []
            for hash_cd in reports[report]:
                df = reports[report][hash_cd].map(
                    add_br_after_error_none_ok)
                datas.append("<br>".join([f"<b>{element}</b>" for element in
                                          hashes[report][
                                              hash_cd]]) + df.to_html(
                    index=False, escape=False))
            file.write(add_style_block('<br><br>'.join(datas)))


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
