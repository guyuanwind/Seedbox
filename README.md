### 一键重装脚本
```
wget --no-check-certificate -qO InstallNET.sh 'https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh' && chmod a+x InstallNET.sh && bash InstallNET.sh -debian 12 -pwd 'password'
```

### qb部署脚本
**杰大**
```
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Dedicated-Seedbox/main/Install.sh) -u <用戶名稱> -p <密碼> -c <緩存大小(單位:MiB)> -q <qBittorrent 版本> -l <libtorrent 版本> -b -v -r -3 -x -o
```

项目地址：https://github.com/jerry048/Dedicated-Seedbox/blob/main/README-zh.md

**胡师傅**
```
bash <(wget -qO- https://raw.githubusercontent.com/iniwex5/tools/refs/heads/main/NC_QB438.sh) username password webuiport btport
```

项目地址：https://github.com/iniwex5/tools

### unzip mediainfo docker安装
```
sudo apt update && sudo apt install -y unzip && sudo apt install -y mediainfo && bash <(curl -sL 'https://get.docker.com')
```
### ffmpeg安装
```
bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/install_ffmpeg.sh)
```
### publish-helper安装
```
bash <(wget -qO- https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/publish-helper.sh) 保存目录 媒体目录
```

举例:
```
bash <(wget -qO- https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/publish-helper.sh) /root/publisher-help /root/qb
```

### filebrowser安装
```
bash <(wget -qO- https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/filebrowser.sh) /data/fb-save /data/fb-media
```
第一个参数：fb配置文件保存目录

第二个参数：fb访问文件根目录

举例:
```
bash <(wget -qO- https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/filebrowser.sh) /root/fb /root/qb
```
### openlist安装
```
curl -fsSL https://res.oplist.org/script/v4.sh > install-openlist-v4.sh && sudo bash install-openlist-v4.sh
```

### ffmpeg截图
```
bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/screenshots.sh) "/root/qb/downloads/Young.Sheldon.S04E01.mkv" "/root/qb/screenshots" 00:05:00 00:10:00 00:15:00

```

第一个参数：视频文件完整路径

第二个参数：截图保存位置

后面的参数：截图时间点。几个参数截图几张

### 截图上传
```
bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/PixhostUpload.sh) /path/to/images

```
参数：截图保存目录
