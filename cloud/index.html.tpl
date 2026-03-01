<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Server Status</title>
  <style>
    body { font-family: sans-serif; text-align: center; margin-top: 50px; background-color: #121212; color: #ffffff; } 
    ul { list-style-type: none; padding: 0; } 
    li { background: #333; margin: 5px auto; padding: 10px; width: 200px; border-radius: 5px; }
    .download-btn { background-color: #4caf50; color: white; padding: 15px 32px; text-decoration: none; font-size: 16px; border-radius: 5px; font-weight: bold; display: inline-block; margin-bottom: 10px; transition: background-color 0.3s; }
    .download-btn:hover { background-color: #45a049; }
    .instructions { font-size: 14px; color: #aaaaaa; max-width: 450px; margin: 0 auto 40px auto; line-height: 1.5; }
    .status-container { display: flex; justify-content: center; gap: 40px; margin-bottom: 20px; flex-wrap: wrap; }
    .status-item h2 { margin-bottom: 5px; font-size: 1.2em; color: #ccc; }
    .status-item span { font-size: 1.5em; font-weight: bold; }
  </style>
</head>
<body>
  <h1>Minecraft Server</h1>
  
  <div class="status-container">
    <div class="status-item">
      <h2>Host PC</h2>
      <span id="host-status">Loading...</span>
    </div>
    <div class="status-item">
      <h2>Tunnel</h2>
      <span id="tunnel-status">Loading...</span>
    </div>
    <div class="status-item">
      <h2>Game Server</h2>
      <span id="server-status">Loading...</span>
    </div>
  </div>

  <h3>Players: <span id="players">-</span></h3>
  
  <div style="margin: 40px 0;">
    <a href="/modpack.zip" class="download-btn">Download Modpack</a>
    <p class="instructions">To install: Open the CurseForge app, click <strong>"Create Custom Profile"</strong> at the top right, select the <strong>"Import"</strong> link, and choose this downloaded zip file.</p>
  </div>

  <ul id="player-list"></ul>
  
  <script>
    async function checkStatus() {
      try {
        let hostOnline = false;
        let tunnelOnline = false;
        
        try {
          const healthRes = await fetch("/health.json");
          const healthData = await healthRes.json();
          hostOnline = healthData.host === "online";
          tunnelOnline = healthData.tunnel === "online";
        } catch (err) {
          console.warn("Could not fetch health.json");
        }

        let mcOnline = false;
        let mcData = null;
        
        try {
          const res = await fetch("https://api.mcsrvstat.us/3/${duckdns_domain}.duckdns.org");
          mcData = await res.json();
          mcOnline = mcData.online;
        } catch (err) {
          console.warn("Could not fetch MC status");
        }

        if (!hostOnline) {
          tunnelOnline = false;
          mcOnline = false;
        }
        
        if (!tunnelOnline) {
          mcOnline = false;
        }

        const setStatus = (id, isOnline) => {
          const el = document.getElementById(id);
          if (isOnline) {
            el.innerText = "Online";
            el.style.color = "#4caf50";
          } else {
            el.innerText = "Offline";
            el.style.color = "#f44336";
          }
        };

        setStatus("host-status", hostOnline);
        setStatus("tunnel-status", tunnelOnline);
        setStatus("server-status", mcOnline);

        const playerListUl = document.getElementById("player-list");
        playerListUl.innerHTML = "";
        
        if (mcOnline && mcData.players) {
          document.getElementById("players").innerText = mcData.players.online + " / " + mcData.players.max;
          
          if (mcData.players.list && mcData.players.list.length > 0) {
            mcData.players.list.forEach(player => {
              const li = document.createElement("li");
              li.innerText = player.name;
              playerListUl.appendChild(li);
            });
          }
        } else {
          document.getElementById("players").innerText = "-";
        }
      } catch (err) {
        console.error("Status check encountered an error", err);
      }
    }
    
    checkStatus();
    setInterval(checkStatus, 60000);
  </script>
</body>
</html>