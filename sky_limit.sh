#!/bin/bash
#
# qBittorrent 自动限速服务 (标签版) - 一键安装/更新脚本
# 用法: ./install_sky_limit.sh <端口> <用户名> <密码> <分类名>
# 逻辑: 
#   1. < 1小时: 限速 10KiB
#   2. > 1小时: 限速 450MiB + 添加标签 "1h_over"
#   3. 如果已有 "1h_over" 标签: 跳过，不再处理
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

# --- 3. 定义名称与路径 (已修改) ---
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="sky_limit.py"          # <--- 程序文件名称已修改
SERVICE_NAME="sky_limit.service"    # <--- 服务名称已修改
SCRIPT_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"

echo -e "${GREEN}==> 开始部署 qBittorrent 自动限速服务 [Sky Limit 版]...${NC}"

# --- 4. 环境检查与依赖安装 ---
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

# --- 5. 生成 Python 核心脚本 ---
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
LIMIT_HIGH = 450 * 1024 * 1024 # 450 MiB
AGE_SEC = 3600                 # 1 Hour
INTERVAL = 5                   # Check every 5s
TAG_DONE = "1h_over"           # 完成标记标签

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

    logging.info(f"登录成功 | 监控分类: [{args.cat}] | 标签策略: 完成后添加 [{TAG_DONE}]")

    while True:
        try:
            # 获取特定分类的种子信息
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
                # 检查标签是否存在
                current_tags = t.get('tags', '')
                tag_list = [x.strip() for x in current_tags.split(',')]
                
                if TAG_DONE in tag_list:
                    # 如果已有标签，直接跳过，不做任何检查
                    continue

                age = now - t.get('added_on', 0)
                limit = t.get('up_limit', -1)
                
                # 阶段A: 新手期 (< 1小时) 且 当前未限速到 10K
                if age < AGE_SEC and limit != LIMIT_LOW:
                    logging.info(f"新种限速 -> 10KiB: {t['name'][:30]}")
                    batch_low.append(t['hash'])
                
                # 阶段B: 成熟期 (> 1小时)
                elif age >= AGE_SEC:
                    logging.info(f"时间达标 -> 准备放行并打标签: {t['name'][:30]}")
                    batch_high.append(t['hash'])

            # 执行批量操作
            if batch_low:
                session.post(f'{base_url}/api/v2/torrents/setUploadLimit', data={'hashes': '|'.join(batch_low), 'limit': LIMIT_LOW})
            
            if batch_high:
                hashes_str = '|'.join(batch_high)
                # 1. 设置限速
                session.post(f'{base_url}/api/v2/torrents/setUploadLimit', data={'hashes': hashes_str, 'limit': LIMIT_HIGH})
                # 2. 添加标签
                session.post(f'{base_url}/api/v2/torrents/addTags', data={'hashes': hashes_str, 'tags': TAG_DONE})
                logging.info(f"已处理 {len(batch_high)} 个种子: 速度重置并添加标签 '{TAG_DONE}'")

        except Exception as e:
            logging.error(f"运行循环错误: {e}")
            time.sleep(INTERVAL)
        
        time.sleep(INTERVAL)

if __name__ == '__main__':
    main()
EOF

chmod +x "${SCRIPT_PATH}"

# --- 6. 生成 Systemd 服务文件 ---
echo "--> 生成 Systemd 服务文件: /etc/systemd/system/${SERVICE_NAME}"

cat <<EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=Sky Limit - qBittorrent Auto Limiter
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${SCRIPT_PATH} ${QB_PORT} ${QB_USER} ${QB_PASS} "${QB_CAT}"
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

# --- 7. 启动服务 ---
echo "--> 正在更新并重启服务 [${SERVICE_NAME}]..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

# --- 8. 验证 ---
echo -e "${GREEN}==> 部署完成！${NC}"
echo "------------------------------------------------"
echo "服务名称: ${SERVICE_NAME}"
echo "脚本路径: ${SCRIPT_PATH}"
echo "------------------------------------------------"
echo "正在检查服务日志..."
sleep 2
journalctl -u "${SERVICE_NAME}" -n 10 --no-pager
