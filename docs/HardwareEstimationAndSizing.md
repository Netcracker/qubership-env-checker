# Hardware Estimation and Sizing

This document describes the hardware requirements for the Environment Checker solution.

## Hardware Profiles

Environment checker service deployment artifact contains the following list of services:

| Service Name                 | DNS Name            | Type     | Description                                                                                                                                                                                             |
| ---------------------------- | ------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Environment Checker pod      | env-checker         | Service  | The main microservice is built on the third-party development environment Jupiter Notebooks. The microservice pods act as both the backend and frontend component.                                      |
| Environment Checker job      | env-checker-job     | Job      | Job deploys its own JupiterLab as a Job, allowing for script execution and subsequent reporting to s3 and monitoring. The Job is designed to address security issues within the production environment. |
| Environment Checker cron-job | env-checker-cronjob | Cron-job | CronJob performs periodic tasks at specified intervals for uninterrupted infrastructure monitoring and the ability to send result reports to s3 and monitoring.                                         |

The microservice Pods with the Service type exist continuously, while the Pods of type Job are deleted after a one-time execution and fulfillment of their role. The CronJob type functions similarly to a Job but follows a schedule for repeated executions.

This Memory\CPU usage, which is primarily justified by the support of the third-party Jupiter Notebooks. On average, a significant portion of resources is allocated for idle work, and the excess is dedicated to running various script-checking tasks.

| Name                | Type     | CPU request (m) | Memory request(Gi) | CPU limit (m) | Memory limit (Gi) | Replicas |
| ------------------- | -------- | --------------- | ------------------ | ------------- | ----------------- | -------- |
| env-checker         | Service  | 100             | 1                  | 1000          | 2                 | 1        |
| env-checker-job     | Job      | 100             | 1                  | 1000          | 2                 | 1        |
| env-checker-cronjob | Cron-job | 100             | 1                  | 1000          | 2                 | 1        |

Total number of CPU and Memory, in case of using all services simultaneously:  
Total RAM request for prod profile: **3072Mi**  
Total RAM limit for prod profile: **6144Mi**

Total CPU request for prod profile: **300m**  
Total CPU limit for prod profile: **3000m** (in fact, JOB will be completed soon, hence 2000m is max consumption in runtime)
