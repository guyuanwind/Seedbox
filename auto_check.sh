#!/bin/bash
#
# qBittorrent Stalled Torrent Rechecker - Version 2.0 (Final)
# A self-contained script that auto-installs Python 3.7.4 if not present,
# along with its own dependencies, and provides silent/verbose execution modes.
#

# ==============================================================================
# Part 1: Bash 启动器, Python环境和依赖安装程序
# ==============================================================================

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_NC='\033[0m'

# --- 函数：从源码安装 Python 3.7.4 ---
function install_python_from_source() {
    local version="3.7.4"
    echo -e "${C_YELLOW}检测到系统中没有Python 3, 将从源码编译安装 Python ${version}...${C_NC}"
    echo -e "${C_YELLOW}警告: 此过程可能需要10-30分钟，请耐心等待。${C_NC}"
    sleep 5

    # 1. 安装编译Python所需的系统依赖
    echo "--> 步骤 1/4: 安装系统编译依赖..."
    apt-get update -y
    apt-get install -y build-essential libncurses5-dev libgdbm-dev libnss3-dev \
                       libssl-dev libreadline-dev libffi-dev zlib1g-dev make wget curl

    # 2. 下载Python源码
    echo "--> 步骤 2/4: 下载 Python ${version} 源码..."
    if [ ! -f "Python-${version}.tgz" ]; then
        wget "https://www.python.org/ftp/python/${version}/Python-${version}.tgz"
        if [ $? -ne 0 ]; then
            echo -e "${C_RED}下载 Python 源码失败, 请检查网络。${C_NC}"
            exit 1
        fi
    else
        echo "源码包已存在, 跳过下载。"
    fi
    
    # 3. 解压、编译和安装
    echo "--> 步骤 3/4: 解压并编译源码 (此步骤最耗时)..."
    tar -zxvf "Python-${version}.tgz"
    cd "Python-${version}" || exit 1
    ./configure --prefix="/usr/local/python-${version}" --enable-optimizations
    make && make install
    if [ $? -ne 0 ]; then
        echo -e "${C_RED}Python 编译或安装失败, 请检查错误日志。${C_NC}"
        exit 1
    fi
    cd ..

    # 4. 创建软链接
    echo "--> 步骤 4/4: 创建 python3 和 pip3 软链接..."
    ln -sf "/usr/local/python-${version}/bin/python3.7" /usr/bin/python3
    ln -sf "/usr/local/python-${version}/bin/pip3.7" /usr/bin/pip3
    
    # 清理
    rm -rf "Python-${version}" "Python-${version}.tgz"

    echo -e "${C_GREEN}Python ${version} 安装成功！${C_NC}"
}


# --- 主逻辑开始 ---
echo -e "${C_GREEN}启动qBittorrent停滞任务脚本 (v2.0)...${C_NC}"

# 检查Python环境
if ! command -v python3 &> /dev/null; then
    install_python_from_source
fi

# 再次检查Python环境
if ! command -v python3 &> /dev/null; then
    echo -e "${C_RED}尝试安装Python后依然无法找到 'python3' 命令, 脚本退出。${C_NC}"
    exit 1
fi

# 检查qchecker脚本的参数
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    : # 交由Python处理帮助信息
elif [ "$#" -lt 3 ]; then
    echo -e "${C_RED}错误: 至少需要 端口号、用户名、密码 这三个参数。${C_NC}"
    echo "用法: $0 <端口号> <用户名> <密码> [-debug] [可选参数...]"
    exit 1
fi

# 检查requests库
if ! python3 -c "import requests" 2>/dev/null; then
    echo -e "${C_YELLOW}未找到 Python 'requests' 库，正在尝试自动安装...${C_NC}"
    # 优先使用 apt
    if command -v apt-get &> /dev/null && apt-get install -y python3-requests &> /dev/null; then
        echo "通过 apt 安装 python3-requests 成功。"
    else
        # apt失败或不存在，则使用 pip3
        if ! command -v pip3 &> /dev/null; then
            echo -e "${C_RED}未找到 pip3 命令，且无法通过 apt 安装 requests 库。${C_NC}"
            exit 1
        fi
        pip3 install requests
    fi
    # 最终检查
    if ! python3 -c "import requests" 2>/dev/null; then
        echo -e "${C_RED}安装 'requests' 库失败。请检查系统环境。${C_NC}"
        exit 1
    fi
    echo -e "${C_GREEN}'requests' 库安装成功！${C_NC}"
fi

# ==============================================================================
# Part 2: 嵌入式 Python 代码 (与v13版本相同)
# ==============================================================================
python3 - "$@" << 'EOF'

# (此处嵌入的Python代码与上一版v13完全相同，为了简洁省略，实际使用时请将v13的Python代码完整粘贴于此)
import requests
import time
import logging
import argparse
import sys
import os

def login(session, base_url, username, password):
    login_url = f'{base_url}/api/v2/auth/login'
    login_data = {'username': username, 'password': password}
    try:
        response = session.post(login_url, data=login_data, timeout=10)
        response.raise_for_status()
        if response.text == 'Ok.':
            logging.info("登录成功！")
            return session
        else:
            err_msg = f"登录失败: {response.text}"
            logging.error(err_msg)
            if '-debug' in sys.argv: print(err_msg, file=sys.stderr)
            return None
    except requests.exceptions.RequestException as e:
        err_msg = f"连接 qBittorrent WebUI ({base_url}) 失败: {e}"
        logging.error(err_msg)
        if '-debug' in sys.argv: print(err_msg, file=sys.stderr)
        return None

def get_torrents(session, base_url):
    torrents_info_url = f'{base_url}/api/v2/torrents/info'
    try:
        params = {}
        response = session.get(torrents_info_url, params=params, timeout=10)
        response.raise_for_status()
        return response.json()
    except (requests.exceptions.RequestException, ValueError) as e:
        logging.error(f"获取或解析种子列表失败: {e}")
        return None

def print_status_table(torrents):
    os.system('cls' if os.name == 'nt' else 'clear')
    print(f"--- qBittorrent 种子状态实时监控 [{time.strftime('%Y-%m-%d %H:%M:%S')}] ---")
    if torrents is None:
        print("未能获取到种子信息。")
        return
        
    print(f"共获取到 {len(torrents)} 个种子。")
    print("="*85)
    print(f"{'Torrent Name'.ljust(40)} | {'State (Raw)'.ljust(20)} | {'Progress'.ljust(10)} | {'Will Recheck?'}")
    print(f"{'-'*40}-|-{'-'*20}-|-{'-'*10}-|-{'-'*15}")

    rechecked_this_round = False
    for torrent in torrents:
        name = torrent.get('name', 'N/A')
        if len(name) > 38: name = name[:35] + "..."
        state = torrent.get('state', '')
        progress = torrent.get('progress', 0)
        dlspeed = torrent.get('dlspeed', 0)
        progress_rounded = round(progress, 4)
        
        will_recheck = state == 'stalledDL' and 0.99 < progress and progress_rounded <= 1.0 and dlspeed == 0
        if will_recheck:
            rechecked_this_round = True

        print(f"{name.ljust(40)} | {state.ljust(20)} | {f'{progress:.4f}'.ljust(10)} | {'YES' if will_recheck else 'NO'}")
    
    print("="*85)
    if not rechecked_this_round:
        logging.info("本轮未发现需要重新校验的种子。")

def main_loop(args, session, base_url):
    while True:
        try:
            torrents = get_torrents(session, base_url)
            
            if torrents is None:
                 logging.warning("获取种子列表失败，尝试重新登录...")
                 if not login(session, base_url, args.user, args.password):
                     logging.error("重新登录失败，将在下一个周期重试。")
                     time.sleep(args.interval)
                     continue
                 else:
                     torrents = get_torrents(session, base_url)
                     if torrents is None:
                         time.sleep(args.interval)
                         continue
            
            if args.debug:
                print_status_table(torrents)

            hashes_to_recheck = []
            for torrent in torrents:
                state = torrent.get('state', '')
                progress = torrent.get('progress', 0)
                dlspeed = torrent.get('dlspeed', 0)
                progress_rounded = round(progress, 4)
                
                if state == 'stalledDL' and 0.99 < progress and progress_rounded <= 1.0 and dlspeed == 0:
                    logging.info(f"发现符合条件的种子: '{torrent['name']}'，准备重新校验...")
                    hashes_to_recheck.append(torrent['hash'])
            
            if hashes_to_recheck:
                logging.info(f"正在对 {len(hashes_to_recheck)} 个种子发送强制重新校验请求...")
                recheck_url = f'{base_url}/api/v2/torrents/recheck'
                recheck_data = {'hashes': '|'.join(hashes_to_recheck)}
                try:
                    response = session.post(recheck_url, data=recheck_data, timeout=10)
                    response.raise_for_status()
                    logging.info("请求已成功发送。")
                except requests.exceptions.RequestException as e:
                    logging.error(f"发送重新校验请求失败: {e}")
            
            logging.info(f"检查完成，将在 {args.interval} 秒后进行下一轮。")
            time.sleep(args.interval)

        except KeyboardInterrupt:
            if args.debug: print("\n", end="") 
            logging.info("脚本被用户手动停止。")
            break
        except Exception as e:
            logging.critical(f"发生意外错误: {e}")
            if not args.debug:
                time.sleep(args.interval)
                pass
            else:
                sys.exit(1)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description="一个集成了实时监控和后台静默模式的qBittorrent任务管理脚本。",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-debug', action='store_true', help="【实时监控模式】持续执行并在每次循环时打印详细的种子信息和日志。")
    parser.add_argument('port', metavar='PORT', type=int)
    parser.add_argument('user', metavar='USERNAME', type=str)
    parser.add_argument('password', metavar='PASSWORD', type=str)
    parser.add_argument('--host', type=str, default='localhost')
    parser.add_argument('-i', '--interval', type=int, default=180)
    
    args = parser.parse_args()
    
    if args.debug:
        logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', datefmt='%H:%M:%S')
    else:
        logging.getLogger().disabled = True

    base_url = f'http://{args.host}:{args.port}'
    session = requests.Session()

    if not login(session, base_url, args.user, args.password):
        sys.exit(1)

    main_loop(args, session, base_url)
EOF
