{{/*
Standard chart helpers — name, fullname, labels, selectorLabels, serviceAccountName.
Mirrors the shape used by helm/crashy-app so operators recognize it.
*/}}

{{- define "smartops-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "smartops-controller.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "smartops-controller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "smartops-controller.labels" -}}
helm.sh/chart: {{ include "smartops-controller.chart" . }}
{{ include "smartops-controller.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: smartops-lite
app.kubernetes.io/component: controller
{{- end -}}

{{- define "smartops-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "smartops-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "smartops-controller.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "smartops-controller.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
