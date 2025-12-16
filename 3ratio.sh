#!/bin/bash
#
# qBittorrent 智能分享率限速服务 (修正版 v2)
# 修复问题: 增加 API 返回值校验，确保限速成功后才打标签
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
if [ "$#" -lt 3 ]; then
    echo -e "${RED}参数不足！${NC}"
    echo "用法: $0 <端口> <用户名> <密码> [分类列表]"
    exit 1
fi

QB_PORT=$1
QB_USER=$2
QB_PASS=$3
QB_CATS=${4:-""}

# 定义安装路径
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="qb_ratio_limit_daemon.py"
SERVICE_NAME="qb_ratio_limit.service"
SCRIPT_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"

echo -e "${GREEN}==> 正在更新 qBittorrent 智能限速服务 (带校验版)...${NC}"

# --- 3. 环境检查 ---
if ! command -v python3 &> /dev/null; then apt-get update && apt-get install -y python3; fi
if ! python3 -c "import requests" 2>/dev/null; then pip3 install requests; fi

# --- 4. 生成 Python 核心脚本 ---
mkdir -p "${INSTALL_DIR}"

cat << 'EOF' > "${SCRIPT_PATH}"
import requests
import time
import sys
import logging
import argparse

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s', datefmt='%H:%M:%S')

LIMIT_TARGET = 10 * 1024       # 10 KiB
RATIO_THRESHOLD = 3.2          # 分享率阈值
INTERVAL = 10                  # 检测间隔(秒)
TAG_DONE = "3ratio"            # 完成标签

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
    parser.add_argument('cats', type=str, nargs='?', default='') 
    args = parser.parse_args()

    base_url = f'http://localhost:{args.port}'
    session = requests.Session()

    logging.info(f"正在登录 (端口: {args.port})...")
    if not login(session, base_url, args.user, args.pwd):
        logging.error("登录失败，请检查账号密码。")
        sys.exit(1)

    sources = []
    if not args.cats or args.cats.strip() == "":
        logging.info("监控模式: [全局监控]")
        sources.append( ("全局", {}) )
    else:
        cat_list = [c.strip() for c in args.cats.split(',') if c.strip()]
        logging.info(f"监控模式: [指定分类] {cat_list}")
        for c in cat_list:
            sources.append( (c, {'category': c}) )

    logging.info(f"策略: Ratio >= {RATIO_THRESHOLD} -> 限速10K (严格校验模式)")

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
                    current_tags = t.get('tags', '')
                    tag_list = [x.strip() for x in current_tags.split(',')]
                    
                    # 1. 如果已有标签，绝对不碰
                    if TAG_DONE in tag_list: continue

                    total_size = t.get('total_size', 0)
                    if total_size == 0: continue
                    uploaded = t.get('uploaded', 0)
                    current_ratio = uploaded / total_size

                    if current_ratio >= RATIO_THRESHOLD:
                        logging.info(f"[{label}] 发现达标任务: {t['name'][:20]}... (R={current_ratio:.2f})")
                        batch_limit.append(t['hash'])

                if batch_limit:
                    hashes_str = '|'.join(batch_limit)
                    
                    # --- 核心修改: 分步执行并校验 ---
                    
                    # 动作 1: 设置限速
                    url_limit = f'{base_url}/api/v2/torrents/setUploadLimit'
                    resp_limit = session.post(url_limit, data={'hashes': hashes_str, 'limit': LIMIT_TARGET})
                    
                    if resp_limit.status_code == 200:
                        # 只有限速成功了，才打标签
                        logging.info(f"[{label}] 限速指令成功。正在添加标签...")
                        session.post(f'{base_url}/api/v2/torrents/addTags', data={'hashes': hashes_str, 'tags': TAG_DONE})
                        logging.info(f"[{label}] ✅ 已成功处理 {len(batch_limit)} 个任务。")
                    else:
                        # 如果限速失败，打印详细错误，并且【不打标签】，这样下次循环还会重试
                        logging.error(f"[{label}] ❌ 限速请求失败! HTTP状态码: {resp_limit.status_code}")
                        logging.error(f"[{label}] 错误详情: {resp_limit.text}")

            except Exception as e:
                logging.error(f"运行错误: {e}")
        
        time.sleep(INTERVAL)

if __name__ == '__main__':
    main()
EOF

chmod +x "${SCRIPT_PATH}"

# --- 5. 重启服务 ---
cat <<EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=qBittorrent Auto Limiter Daemon
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
systemctl restart "${SERVICE_NAME}"

echo -e "${GREEN}==> 服务已更新！${NC}"
echo "------------------------------------------------"
echo "重要提示: 对于之前脚本漏掉的种子（已打标签但未限速）："
echo "请务必手动在 qBittorrent 中删除 '3ratio' 标签，"
echo "否则新脚本会以为它已经处理过了而跳过它！"
echo "------------------------------------------------"
echo "正在查看日志..."
sleep 2
journalctl -u "${SERVICE_NAME}" -f
