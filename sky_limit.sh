#!/bin/bash
#
# qBittorrent 自动限速服务 - 一键安装/更新脚本
# 用法: ./install_qb_limit.sh <端口> <用户名> <密码> <分类名>
# 逻辑: 仅基于时间。 < 1小时 = 10KiB | > 1小时 = 450MiB
#

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# --- 1. 检查 Root 权限 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行此脚本 (sudo bash ...)${NC}"
  exit 1
fi

# --- 2. 检查参数 ---
if [ "$#" -lt 4 ]; then
    echo -e "${RED}参数不足！${NC}"
    echo "用法: $0 <端口> <用户名> <密码> <分类名称>"
    echo "示例: $0 8080 admin 123456 PT-Upload"
    exit 1
fi

QB_PORT=$1
QB_USER=$2
QB_PASS=$3
QB_CAT=$4

# 定义安装路径
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="qb_auto_limit_daemon.py"
SERVICE_NAME="qb_limit.service"
SCRIPT_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"

echo -e "${GREEN}==> 开始部署 qBittorrent 自动限速服务 (450MiB版)...${NC}"

# --- 3. 环境检查与依赖安装 ---
echo "--> 检查 Python 环境..."
if ! command -v python3 &> /dev/null; then
    echo "正在安装 Python3..."
    apt-get update && apt-get install -y python3
fi

echo "--> 检查 Python Requests 库..."
if ! python3 -c "import requests" 2>/dev/null; then
    echo "正在安装 python3-requests..."
    if command -v apt-get &> /dev/null; then
        apt-get install -y python3-requests
    else
        pip3 install requests
    fi
fi

# --- 4. 生成 Python 核心脚本 ---
echo "--> 生成核心脚本: ${SCRIPT_PATH}"
mkdir -p "${INSTALL_DIR}"

# 使用 'EOF' 防止 Shell 解析 Python 代码中的变量
cat << 'EOF' > "${SCRIPT_PATH}"
import requests
import time
import sys
import logging
import argparse

# 配置: 日志输出到标准输出，由 Systemd 捕获
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s', datefmt='%H:%M:%S')

# 常量定义
LIMIT_LOW = 10 * 1024          # 10 KiB
LIMIT_HIGH = 450 * 1024 * 1024 # 450 MiB (已修改)
AGE_SEC = 3600                 # 1 Hour
INTERVAL = 5                   # Check every 5s

def login(session, url, u, p):
    try:
        r = session.post(f'{url}/api/v2/auth/login', data={'username': u, 'password': p}, timeout=10)
        return r.text == "Ok."
    except Exception as e:
        logging.error(f"登录异常: {e}")
        return False

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('port', type=int)
    parser.add_argument('user', type=str)
    parser.add_argument('pwd', type=str)
    parser.add_argument('cat', type=str)
    args = parser.parse_args()

    base_url = f'http://localhost:{args.port}'
    session = requests.Session()

    logging.info(f"正在尝试登录 qBittorrent (端口: {args.port})...")
    if not login(session, base_url, args.user, args.pwd):
        logging.error("登录失败，请检查账号密码。服务即将退出。")
        sys.exit(1)

    logging.info(f"登录成功 | 监控分类: [{args.cat}] | 策略: <1h=10KiB, >1h=450MiB")

    while True:
        try:
            r = session.get(f'{base_url}/api/v2/torrents/info', params={'category': args.cat}, timeout=10)
            if r.status_code != 200: 
                logging.warning("Cookie失效，尝试重连...")
                if login(session, base_url, args.user, args.pwd): continue
                else: 
                    time.sleep(INTERVAL)
                    continue
            
            torrents = r.json()
            now = time.time()
            batch_low = []
            batch_high = []

            for t in torrents:
                age = now - t.get('added_on', 0)
                limit = t.get('up_limit', -1)
                
                # 阶段A: 新手期 (< 1小时) 且 当前未限速到 10K
                if age < AGE_SEC and limit != LIMIT_LOW:
                    logging.info(f"新种限速 -> 10KiB: {t['name'][:30]}")
                    batch_low.append(t['hash'])
                
                # 阶段B: 成熟期 (> 1小时) 且 当前未放行到 450M
                elif age >= AGE_SEC and limit != LIMIT_HIGH:
                    logging.info(f"老种放行 -> 450MiB: {t['name'][:30]}")
                    batch_high.append(t['hash'])

            if batch_low:
                session.post(f'{base_url}/api/v2/torrents/setUploadLimit', data={'hashes': '|'.join(batch_low), 'limit': LIMIT_LOW})
            if batch_high:
                session.post(f'{base_url}/api/v2/torrents/setUploadLimit', data={'hashes': '|'.join(batch_high), 'limit': LIMIT_HIGH})

        except Exception as e:
            logging.error(f"运行循环错误: {e}")
            time.sleep(INTERVAL)
        
        time.sleep(INTERVAL)

if __name__ == '__main__':
    main()
EOF

chmod +x "${SCRIPT_PATH}"

# --- 5. 生成 Systemd 服务文件 ---
echo "--> 生成 Systemd 服务文件: /etc/systemd/system/${SERVICE_NAME}"

# 这里使用 EOF (不带引号) 以便注入 Bash 变量
cat <<EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=qBittorrent Auto Limiter Daemon
After=network.target

[Service]
Type=simple
User=root
# 启动命令直接包含参数，由安装脚本写入
ExecStart=/usr/bin/python3 ${SCRIPT_PATH} ${QB_PORT} ${QB_USER} ${QB_PASS} "${QB_CAT}"
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

# --- 6. 启动服务 ---
echo "--> 正在注册并启动服务..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

# --- 7. 验证 ---
echo -e "${GREEN}==> 部署完成！${NC}"
echo "------------------------------------------------"
echo "查看运行状态: systemctl status ${SERVICE_NAME}"
echo "查看实时日志: journalctl -u ${SERVICE_NAME} -f"
echo "停止服务:     systemctl stop ${SERVICE_NAME}"
echo "卸载服务:     rm ${SCRIPT_PATH} && systemctl disable --now ${SERVICE_NAME} && rm /etc/systemd/system/${SERVICE_NAME}"
echo "------------------------------------------------"

# 自动显示最后几行日志以确认运行
sleep 2
echo "正在检查服务启动日志..."
journalctl -u "${SERVICE_NAME}" -n 5 --no-pager
