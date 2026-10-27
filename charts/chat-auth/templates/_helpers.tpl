{{- define "chat-auth.name" -}}
chat-auth
{{- end }}

{{- define "chat-auth.fullname" -}}
{{- printf "%s" (include "chat-auth.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "chat-auth.labels" -}}
app.kubernetes.io/name: {{ include "chat-auth.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
