{{/*
Find a env-checker image in various places.
Image can be found from:
* specified by user from .Values.IMAGE_REPOSITORY and .Values.TAG
* default value
*/}}
{{- define "env-checker.image" -}}
  {{- if and (not (empty .Values.IMAGE_REPOSITORY)) (not (empty .Values.TAG)) -}}
    {{- printf "%s:%s" .Values.IMAGE_REPOSITORY .Values.TAG -}}
  {{- else -}}
    {{- printf "ghcr.io/netcracker/qubership-env-checker:main" -}}
  {{- end -}}
{{- end -}}
