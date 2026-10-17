{{/* 基础名称与标签 */}}
{{- define "crud-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "crud-app.fullname" -}}
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

{{- define "crud-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* 通用标签 */}}
{{- define "crud-app.labels" -}}
helm.sh/chart: {{ include "crud-app.chart" . }}
app.kubernetes.io/part-of: {{ include "crud-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/* 各组件独立标签：传入 dict "ctx" . "component" "backend" */}}
{{- define "crud-app.componentLabels" -}}
{{ include "crud-app.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/name: {{ include "crud-app.fullname" .ctx }}-{{ .component }}
{{- end -}}

{{- define "crud-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "crud-app.fullname" .ctx }}-{{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{/* MySQL Secret 名称 */}}
{{- define "crud-app.mysqlSecretName" -}}
{{- if .Values.mysql.auth.existingSecret -}}
{{- .Values.mysql.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-mysql" (include "crud-app.fullname" .) -}}
{{- end -}}
{{- end -}}
