#!/opt/conda/bin/python

import json
import sys
try:
    data = json.load(sys.stdin)
    for cell in data['cells']:
        metadata = cell['metadata']
        if 'tags' in metadata:
            tags = metadata['tags']
            if 'result' in tags:
                print(cell['outputs'][0]['data']['text/plain'][0])
                result=0
except (RuntimeError, TypeError, NameError):
     print("Oops! Cannot get result tag from notebook")