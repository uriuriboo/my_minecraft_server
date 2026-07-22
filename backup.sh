#!/bin/bash
cd ~/papermc
docker exec papermc rcon-cli save-off
docker exec papermc rcon-cli save-all
sleep 5
tar czf /home/pi/backups/world_$(date +%F_%H%M).tar.gz -C data world world_nether world_the_end
docker exec papermc rcon-cli save-on

# 7日以上前のバックアップを削除
find /home/pi/backups -name "world_*.tar.gz" -mtime +7 -delete
