#!/bin/bash
#
# qBittorrent 智能限速服务 (3ratio)
# 功能: 分享率 >= 3.3 时自动限速并打标签
# 频率: 5秒/次
#

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# --- 检查权限 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行${NC}"
  exit 1
fi

# --- 检查参数 ---
if [ "$#" -lt 3 ]; then
    echo -e "${RED}参数不足${NC}"
    echo "用法: $0 <端口> <用户名> <密码> [分类列表]"
    exit 1
fi

QB_PORT=$1
QB_USER=$2
QB_PASS=$3
QB_CATS=${4:-""}

INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="3ratio.py"
SERVICE_NAME="3ratio.service"
SCRIPT_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"

echo -e "${GREEN}==> 正在部署 3ratio 服务 (Ratio=3.3, Interval=5s)...${NC}"

# --- 环境检查 ---
if ! command -v python3 &> /dev/null; then apt-get update && apt-get install -y python3; fi
if ! python3 -c "import requests" 2>/dev/null; then pip3 install requests; fi

# --- 生成 Python 脚本 ---
mkdir -p "${INSTALL_DIR}"

cat << 'EOF' > "${SCRIPT_PATH}"
import requests
import time
import sys
import logging
import argparse

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s', datefmt='%H:%M:%S')

LIMIT_TARGET = 10 * 1024       # 10 KiB
RATIO_THRESHOLD = 3.3          # 阈值 3.3
INTERVAL = 5                   # 间隔 5s (修改点)
TAG_DONE = "3ratio"            # 完成标记

def login(session, url, u, p):
    try:
        r = session.post(f'{url}/api/v2/auth/login', data={'username': u, 'password': p}, timeout=10)
        return r.text == "Ok."
    except:
        return False

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('port', type=int)
    parser.add_argument('user', type=str)
    parser.add_argument('pwd', type=str)
    parser.add_argument('cats', type=str, nargs='?', default='') 
    args = parser.parse_args()

    base_url = f'http://localhost:{args.port}'
    session = requests.Session()

    logging.info(f"正在登录端口: {args.port}...")
    if not login(session, base_url, args.user, args.pwd):
        logging.error("登录失败")
        sys.exit(1)

    sources = []
    if not args.cats or args.cats.strip() == "":
        logging.info("模式: 全局监控")
        sources.append( ("全局", {}) )
    else:
        cat_list = [c.strip() for c in args.cats.split(',') if c.strip()]
        logging.info(f"模式: 分类监控 {cat_list}")
        for c in cat_list:
            sources.append( (c, {'category': c}) )

    logging.info(f"策略: Ratio >= {RATIO_THRESHOLD} -> 限速10K (每5秒检查)")

    while True:
        for label, params in sources:
            try:
                r = session.get(f'{base_url}/api/v2/torrents/info', params=params, timeout=30)
                if r.status_code != 200: 
                    if login(session, base_url, args.user, args.pwd): 
                        r = session.get(f'{base_url}/api/v2/torrents/info', params=params, timeout=30)
                    else: break 
                 
                torrents = r.json()
                batch_limit = []

                for t in torrents:
                    # 跳过已处理
                    if TAG_DONE in t.get('tags', ''): continue
                    
                    # 计算分享率
                    total_size = t.get('total_size', 0)
                    if total_size == 0: continue
                    current_ratio = t.get('uploaded', 0) / total_size

                    if current_ratio >= RATIO_THRESHOLD:
                        logging.info(f"[{label}] 达标: {t['name'][:20]}... (R={current_ratio:.2f})")
                        batch_limit.append(t['hash'])

                if batch_limit:
                    hashes_str = '|'.join(batch_limit)
                    
                    # 执行限速
                    url_limit = f'{base_url}/api/v2/torrents/setUploadLimit'
                    resp = session.post(url_limit, data={'hashes': hashes_str, 'limit': LIMIT_TARGET})
                     
                    # 校验并打标签
                    if resp.status_code == 200:
                        session.post(f'{base_url}/api/v2/torrents/addTags', data={'hashes': hashes_str, 'tags': TAG_DONE})
                        logging.info(f"[{label}] 处理完成: {len(batch_limit)} 个")
                    else:
                        logging.error(f"[{label}] 限速失败: {resp.status_code}")

            except Exception as e:
                logging.error(f"错误: {e}")
        
        time.sleep(INTERVAL)

if __name__ == '__main__':
    main()
EOF

chmod +x "${SCRIPT_PATH}"

# --- 配置服务 ---
cat <<EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=qBittorrent Auto Limiter Daemon (3ratio)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${SCRIPT_PATH} ${QB_PORT} ${QB_USER} ${QB_PASS} "${QB_CATS}"
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo -e "${GREEN}==> 服务 [3ratio] 已更新! (5秒检测版)${NC}"
echo "------------------------------------------------"
echo "日志监控中 (Ctrl+C 退出)..."
sleep 1
journalctl -u "${SERVICE_NAME}" -f
