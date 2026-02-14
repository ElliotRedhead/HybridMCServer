${duckdns_domain}.duckdns.org {
    root * /usr/share/caddy
    file_server
}

${duckdns_domain}.duckdns.org:7500 {
    reverse_proxy 127.0.0.1:7501
}