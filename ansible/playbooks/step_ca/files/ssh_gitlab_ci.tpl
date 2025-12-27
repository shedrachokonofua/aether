{
    "type": {{ toJson .Type }},
    "keyId": {{ toJson .KeyID }},
    {{- if .Token.project_path }}
    "principals": [
        {{ printf "gitlab-ci/%s" .Token.project_path | toJson }},
        {{- if .Token.ref }}
        {{ printf "gitlab-ci/%s/%s" .Token.project_path .Token.ref | toJson }},
        {{- end }}
        {{- if .Token.environment }}
        {{ printf "gitlab-ci/%s/env/%s" .Token.project_path .Token.environment | toJson }},
        {{- end }}
        "gitlab-ci"
    ],
    {{- else }}
    "principals": ["gitlab-ci"],
    {{- end }}
    "extensions": {
        "permit-pty": "",
        "permit-agent-forwarding": ""
    }
}
