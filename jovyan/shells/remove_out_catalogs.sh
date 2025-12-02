#!/bin/bash

out_dir="/home/jovyan/out"
threshold_time=$(date -d '1 hour ago' +%s)

#  Looping through folders inside the `out` folder
for folder in "$out_dir"/*; do
  if [[ -d "$folder" ]]; then  # Check that this is a directory
    folder_creation_time=$(stat -c "%Y" "$folder")

    # Checking that the folder was created more than an hour ago
    if [[ $folder_creation_time -lt $threshold_time ]]; then
      echo "Removing folder: $folder"
      rm -rf "$folder" # Removing folder
    fi
  fi
done