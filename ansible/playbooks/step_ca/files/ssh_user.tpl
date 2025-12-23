{
    "type": {{ toJson .Type }},
    "keyId": {{ toJson .KeyID }},
    "principals": [
        {{ toJson .Token.email }}
        {{- range .Token.roles }},
        {{ toJson . }}
        {{- end }}
    ],
    {{- if has "admin" .Token.roles }}
    "extensions": {
        "permit-pty": "",
        "permit-user-rc": "",
        "permit-agent-forwarding": "",
        "permit-port-forwarding": "",
        "permit-X11-forwarding": ""
    }
    {{- else }}
    "extensions": {
        "permit-pty": ""
    }
    {{- end }}
}

