{{/*
Expand the name of the chart.
*/}}
{{- define "app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Use the Release name directly as fullname to ensure resource names match the ArgoCD Application name.
*/}}
{{- define "app.fullname" -}}
{{- .Release.Name }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.chart" . }}
{{ include "app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels. Strips "dev-" and "prod-" prefix from the Release name to yield the base service name
(e.g., dev-api-gateway -> api-gateway), matching service discovery selectors.
*/}}
{{- define "app.selectorLabels" -}}
app: {{ .Release.Name | replace "dev-" "" | replace "prod-" "" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Release.Name | replace "dev-" "" | replace "prod-" "" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
