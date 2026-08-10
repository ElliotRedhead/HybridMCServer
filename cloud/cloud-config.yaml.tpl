#cloud-config
write_files:
  - path: /opt/caddy/Caddyfile
    content: |
${indent(6, caddyfile_content)}
  - path: /opt/mc-status/index.html
    content: |
${indent(6, index_content)}
