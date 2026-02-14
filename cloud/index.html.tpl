<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Server Status</title>
  <style>body { font-family: sans-serif; text-align: center; margin-top: 50px; background-color: #121212; color: #ffffff; } ul { list-style-type: none; padding: 0; } li { background: #333; margin: 5px auto; padding: 10px; width: 200px; border-radius: 5px; }</style>
</head>
<body>
  <h1>Minecraft Server</h1>
  <h2>Status: <span id="status">Loading...</span></h2>
  <h3>Players: <span id="players">-</span></h3>
  <ul id="player-list"></ul>
  <script>
    async function checkStatus() {
      try {
        const res = await fetch("https://api.mcsrvstat.us/3/${duckdns_domain}.duckdns.org");
        const data = await res.json();
        const playerListUl = document.getElementById("player-list");
        playerListUl.innerHTML = "";
        if (data.online) {
          document.getElementById("status").innerText = "Online";
          document.getElementById("status").style.color = "#4caf50";
          document.getElementById("players").innerText = data.players.online + " / " + data.players.max;
          if (data.players.list && data.players.list.length > 0) {
            data.players.list.forEach(player => {
              const li = document.createElement("li");
              li.innerText = player.name;
              playerListUl.appendChild(li);
            });
          }
        } else {
          document.getElementById("status").innerText = "Offline";
          document.getElementById("status").style.color = "#f44336";
          document.getElementById("players").innerText = "-";
        }
      } catch (err) {
        document.getElementById("status").innerText = "Error";
      }
    }
    checkStatus();
    setInterval(checkStatus, 60000);
  </script>
</body>
</html>