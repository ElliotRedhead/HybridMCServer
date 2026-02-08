serverAddr = "${server_addr}"
serverPort = 7000
auth.method = "token"
auth.token = "${auth_token}"

[[proxies]]
name = "minecraft"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25565
remotePort = 25565