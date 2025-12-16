#!/bin/bash
#
# qBittorrent 智能分享率限速服务 (全功能版) - 一键安装脚本
#
# 用法: 
#   1. ./install_auto_limit.sh <端口> <用户> <密码>              (监控所有种子)
#   2. ./install_auto_limit.sh <端口> <用户> <密码> "PT,Movie"   (监控指定分类)
#
# 逻辑: Ratio >= 3.2 -> 限速 10KiB + 打标签 "3ratio"
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
# 允许只传 3 个参数，第 4 个参数默认为空
if [ "$#" -lt 3 ]; then
    echo -e "${RED}参数不足！${NC}"
    echo "用法: $0 <端口> <用户名> <密码> [分类列表]"
    echo -e "示例 (监控所有): $0 8080 admin 123456"
    echo -e "示例 (指定分类): $0 8080 admin 123456 \"PT-Upload,Movie\""
    exit 1
fi

QB_PORT=$1
QB_USER=$2
QB_PASS=$3
# 如果第4个参数存在则使用，否则为空字符串
QB_CATS=${4:-""}

# 定义安装路径
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="qb_ratio_limit_daemon.py"
SERVICE_NAME="qb_ratio_limit.service"
SCRIPT_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"

echo -e "${GREEN}==> 开始部署 qBittorrent 智能限速服务...${NC}"

# --- 3. 环境检查 ---
if ! command -v python3 &> /dev/null; then
    apt-get update && apt-get install -y python3
fi
if ! python3 -c "import requests" 2>/dev/null; then
    if command -v apt-get &> /dev/null; then apt-get install -y python3-requests; else pip3 install requests; fi
fi

# --- 4. 生成 Python 核心脚本 ---
mkdir -p "${INSTALL_DIR}"

cat << 'EOF' > "${SCRIPT_PATH}"
import requests
import time
import sys
import logging
import argparse

# 配置日志
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s', datefmt='%H:%M:%S')

# --- 常量定义 ---
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
    # nargs='?' 表示该参数可选，default='' 表示默认空字符串
    parser.add_argument('cats', type=str, nargs='?', default='') 
    args = parser.parse_args()

    base_url = f'http://localhost:{args.port}'
    session = requests.Session()

    logging.info(f"正在登录 (端口: {args.port})...")
    if not login(session, base_url, args.user, args.pwd):
        logging.error("登录失败，请检查账号密码。")
        sys.exit(1)

    # --- 决定监控模式 ---
    # sources 是一个列表，包含元组: (显示名称, API查询参数)
    sources = []
    
    if not args.cats or args.cats.strip() == "":
        # 模式 A: 如果参数为空，监控所有 (Params 为空字典，API 返回所有种子)
        logging.info("监控模式: [全局监控] (包括所有分类及无分类)")
        sources.append( ("全局", {}) )
    else:
        # 模式 B: 指定分类
        cat_list = [c.strip() for c in args.cats.split(',') if c.strip()]
        logging.info(f"监控模式: [指定分类] {cat_list}")
        for c in cat_list:
            sources.append( (c, {'category': c}) )

    logging.info(f"策略: Ratio >= {RATIO_THRESHOLD} -> 限速10K + 标签'{TAG_DONE}'")

    while True:
        # 遍历任务列表 (全局模式下只循环一次，指定分类下循环多次)
        for label, params in sources:
            try:
                # logging.debug(f"正在检查: {label}")
                r = session.get(f'{base_url}/api/v2/torrents/info', params=params, timeout=30)
                
                if r.status_code != 200: 
                    logging.warning("Cookie失效，尝试重连...")
                    if login(session, base_url, args.user, args.pwd): 
                        r = session.get(f'{base_url}/api/v2/torrents/info', params=params, timeout=30)
                    else: 
                        break 
                
                torrents = r.json()
                batch_limit = []

                for t in torrents:
                    # 1. 标签检查 (幂等性)
                    current_tags = t.get('tags', '')
                    tag_list = [x.strip() for x in current_tags.split(',')]
                    if TAG_DONE in tag_list: continue

                    # 2. 数据获取
                    total_size = t.get('total_size', 0)
                    if total_size == 0: continue
                    uploaded = t.get('uploaded', 0)
                    current_ratio = uploaded / total_size

                    # 3. 判断逻辑
                    if current_ratio >= RATIO_THRESHOLD:
                        logging.info(f"[{label}] 达标(R={current_ratio:.2f}): {t['name'][:25]}...")
                        batch_limit.append(t['hash'])

                # 4. 批量执行
                if batch_limit:
                    hashes_str = '|'.join(batch_limit)
                    session.post(f'{base_url}/api/v2/torrents/setUploadLimit', data={'hashes': hashes_str, 'limit': LIMIT_TARGET})
                    session.post(f'{base_url}/api/v2/torrents/addTags', data={'hashes': hashes_str, 'tags': TAG_DONE})
                    logging.info(f"[{label}] 已处理 {len(batch_limit)} 个任务。")

            except Exception as e:
                logging.error(f"检查 '{label}' 时出错: {e}")
        
        time.sleep(INTERVAL)

if __name__ == '__main__':
    main()
EOF

chmod +x "${SCRIPT_PATH}"

# --- 5. 生成 Systemd 服务 ---
echo "--> 生成 Systemd 服务文件..."

# 注意：ExecStart 中使用了引号 "${QB_CATS}"，如果为空 bash 会传一个空字符串给 python
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

# --- 6. 启动 ---
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

# --- 7. 结束 ---
echo -e "${GREEN}==> 部署完成！${NC}"
if [ -z "$QB_CATS" ]; then
    echo "当前模式: 全局监控 (所有种子)"
else
    echo "当前模式: 指定分类监控 -> [${QB_CATS}]"
fi
echo "检查日志: journalctl -u ${SERVICE_NAME} -f"
