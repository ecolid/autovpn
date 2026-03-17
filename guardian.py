import requests, time, subprocess, os, json, statistics, sys, socket

VERSION = "1.21.0"
ENV_PATH = "/usr/local/etc/autovpn/.env"

# 优先从 .env 读取 NODE_ID（配对模式），否则使用 hostname
NODE_ID = os.environ.get("NODE_ID") or socket.gethostname()
try:
    with open(ENV_PATH, "r") as f:
        for line in f:
            if line.startswith("NODE_ID="):
                NODE_ID = line.split("=")[1].strip().replace('"', '')
                break
except: pass

# 强制注入 PATH 确保 crontab/systemd 环境正常
os.environ["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


def run_shell(cmd):
    try: return subprocess.getoutput(cmd)
    except: return ""

def get_traffic():
    """
    获取 Xray 流量统计数据
    使用 Xray API 的 statsquery 命令
    输出格式为 protobuf 文本：name 和 value 在不同行
    """
    try:
        res = subprocess.getoutput("/usr/local/bin/xray api statsquery --server=127.0.0.1:10085 2>&1")
        up, down = 0, 0
        lines = res.split("\n")
        current_dir = None
        for line in lines:
            stripped = line.strip()
            if "name:" in stripped:
                if "uplink" in stripped:
                    current_dir = "up"
                elif "downlink" in stripped:
                    current_dir = "down"
                else:
                    current_dir = None
            elif "value:" in stripped and current_dir:
                try:
                    val = int(stripped.split(":")[-1].strip())
                    if val > 0:
                        if current_dir == "up": up += val
                        else: down += val
                except: pass
                current_dir = None
        return {"up": up, "down": down}
    except:
        return {"up": 0, "down": 0}

def measure_quality(target):
    try:
        cmd = f"ping -c 5 -W 2 {target}"
        res = subprocess.getoutput(cmd)
        if "packet loss" in res:
            loss = float(res.split("packet loss")[0].split(",")[-1].replace("%", "").strip())
            times = [float(x.split("=")[-1].replace(" ms", "")) for x in res.split("\n") if "time=" in x]
            if times:
                avg = sum(times) / len(times)
                jitter = statistics.stdev(times) if len(times) > 1 else 0
                return {"lat": round(avg, 2), "jit": round(jitter, 2), "loss": loss}
        return {"lat": 0, "jit": 0, "loss": 100}
    except: return {"lat": 0, "jit": 0, "loss": 100}

def check_health():
    health = {"xray": "OK", "nginx": "OK", "net": "OK", "warp": "SKIP", "loop": "OK"}
    if os.system("/usr/bin/systemctl is-active --quiet xray") != 0: health["xray"] = "FAIL"
    if os.system("/usr/bin/systemctl is-active --quiet nginx") != 0: health["nginx"] = "FAIL"

    if health["xray"] == "FAIL":
        health["loop"] = "FAIL"
    else:
        health["loop"] = "OK"

    warp_active = os.system("/usr/bin/systemctl is-active --quiet warp-svc") == 0
    if warp_active:
        check_cmd = "curl -s --socks5 127.0.0.1:40000 https://api.ipify.org --connect-timeout 2"
        if os.system(check_cmd + " > /dev/null 2>&1") == 0:
            health["warp"] = "OK"
        else:
            warp_res = subprocess.getoutput("warp-cli status 2>/dev/null")
            health["warp"] = "OK" if "Connected" in warp_res else "FAIL"
    elif os.system("command -v warp-cli > /dev/null") == 0:
        health["warp"] = "FAIL"
    else:
        health["warp"] = "SKIP"
    return health

def get_status_data(tid=None, res=None):
    cpu = run_shell("top -bn1 | grep 'Cpu(s)' | awk '{print $2}'")
    mem = run_shell("free | grep Mem | awk '{print $3/$2 * 100.0}'")
    ip = run_shell("curl -s https://api.ipify.org")
    if not ip or len(ip) < 7:
        ip = run_shell("curl -s https://ifconfig.me")
    if not ip or len(ip) < 7:
        ip = run_shell("curl -s https://icanhazip.com")
    if not ip or len(ip) < 7:
        ip = "0.0.0.0"
    data = {
        "id": NODE_ID,
        "hostname": socket.gethostname(),
        "cpu": cpu or "0",
        "mem_pct": mem or "0",
        "v": VERSION,
        "h": check_health(),
        "ip": ip,
        "traff": get_traffic(),
        "qual": {
            "china": measure_quality("223.5.5.5"),
            "global": measure_quality("1.1.1.1")
        }
    }
    if tid: data["task_id"] = tid; data["result"] = res
    return data

def main():
    booted = True
    while True:
        try:
            if not os.path.exists(ENV_PATH): time.sleep(10); continue
            with open(ENV_PATH, "r") as f:
                env = {l.split("=")[0]: l.split("=")[1].strip().replace('"','') for l in f if "=" in l}
            cf_url, c_token = env.get("CF_WORKER_URL", "").rstrip("/"), env.get("CLUSTER_TOKEN")
            if not cf_url: time.sleep(10); continue

            data = get_status_data()
            if booted:
                data["boot"] = True
                booted = False

            r = requests.post(f"{cf_url}/report", json=data, headers={"X-Cluster-Token": c_token}, timeout=10)
            if r.status_code == 200:
                task = r.json()
                if task.get("cmd"):
                    if task["cmd"] == "SELF_UPDATE":
                        res = run_shell("wget -qO /tmp/install.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh && bash /tmp/install.sh --update-bot --silent")
                    else:
                        targets = ["/usr/local/etc/autovpn/install.sh", "/usr/local/bin/autovpn"]
                        target = next((t for t in targets if os.path.exists(t)), "autovpn")

                        if target.startswith("/"):
                            res = run_shell(f"bash {target} {task['cmd']}")
                        else:
                            res = run_shell(f"{target} {task['cmd']}")
                    requests.post(f"{cf_url}/report", json=get_status_data(tid=task['task_id'], res=res),
                                 headers={"X-Cluster-Token": c_token}, timeout=10)
        except: pass
        time.sleep(10)

if __name__ == "__main__": main()
