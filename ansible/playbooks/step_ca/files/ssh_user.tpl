{
    "type": {{ toJson .Type }},
    "keyId": {{ toJson .KeyID }},
    {{- if .Token.email }}
    "principals": {{ toJson (prepend .Token.roles .Token.email) }},
    {{- else }}
    "principals": {{ toJson .Token.roles }},
    {{- end }}
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

