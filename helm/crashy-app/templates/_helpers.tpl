{{/*
Standard chart helpers — name, fullname, labels, selectorLabels, serviceAccountName.
Follows the layout emitted by `helm create` so operators recognize it.
*/}}

{{- define "crashy-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "crashy-app.fullname" -}}
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

{{- define "crashy-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every object created by this chart. Uses the
Kubernetes recommended `app.kubernetes.io/*` prefix so future work like
kube-state-metrics, Prometheus service discovery, and `kubectl get -l`
just work.
*/}}
{{- define "crashy-app.labels" -}}
helm.sh/chart: {{ include "crashy-app.chart" . }}
{{ include "crashy-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: smartops-lite
{{- end -}}

{{/*
Selector labels — must be immutable across chart upgrades. Never add
anything to this list that might change (e.g. version).
*/}}
{{- define "crashy-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "crashy-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "crashy-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "crashy-app.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
