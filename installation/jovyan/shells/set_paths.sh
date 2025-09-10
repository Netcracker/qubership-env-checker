#!/bin/bash

# Setting PATH and PYTHONPATH variables for Kubernetes CronJob and Kubernetes Job
set_paths() {

  if [[ $PATH != *"/home/jovyan/utils"* ]]; then
    export PATH="/home/jovyan/utils:$PATH"
  fi

  if [[ $PATH != *"/home/jovyan/utils/integrations"* ]]; then
    export PATH="/home/jovyan/utils/integrations:$PATH"
  fi

  if [[ $PYTHONPATH != *"/home/jovyan/utils"* ]]; then
    export PYTHONPATH="/home/jovyan/utils:$PYTHONPATH"
  fi

  if [[ $PYTHONPATH != *"/home/jovyan/utils/integrations"* ]]; then
    export PYTHONPATH="/home/jovyan/utils/integrations:$PYTHONPATH"
  fi

}

set_paths "$@"