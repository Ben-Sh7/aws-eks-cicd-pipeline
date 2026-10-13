{{/*
Common labels applied to every resource in this chart.
*/}}
{{- define "task-manager.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Redis needs its password from Secrets Manager, so a local install keeps the
rate-limit counts in the backend's memory instead.
*/}}
{{- define "task-manager.redisEnabled" -}}
{{- if and .Values.redis.enabled (eq .Values.secrets.mode "externalSecrets") }}true{{ end }}
{{- end -}}

{{/*
Spreads one app's pods: by node strictly, by zone where the scheduler can.
Called with the app label, e.g. include "task-manager.topologySpread" "backend".
*/}}
{{- define "task-manager.topologySpread" -}}
- maxSkew: 1
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: DoNotSchedule
  nodeTaintsPolicy: Honor
  labelSelector:
    matchLabels:
      app: {{ . }}
  matchLabelKeys:
    - pod-template-hash
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: ScheduleAnyway
  nodeTaintsPolicy: Honor
  labelSelector:
    matchLabels:
      app: {{ . }}
  matchLabelKeys:
    - pod-template-hash
{{- end -}}
