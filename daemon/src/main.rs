use rand::Rng;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    pub server_url: String,
    #[serde(alias = "node_token")]
    pub token: String,
    #[serde(default = "default_machine_id")]
    pub machine_id: String,
    #[serde(default = "default_hostname")]
    pub hostname: String,
    #[serde(default = "default_mode")]
    pub mode: String, // "cron" | "daemon"
    #[serde(default = "default_min", alias = "report_interval_sec")]
    pub interval_min: u64,
    #[serde(default = "default_max")]
    pub interval_max: u64,
    #[serde(default = "default_node_path", alias = "node_source")]
    pub node_info_path: String,
    #[serde(default = "default_true", alias = "auto_sync_on_change")]
    pub auto_sync: bool,
    #[serde(default = "default_true")]
    pub enable_ippure: bool,
    #[serde(default = "default_true")]
    pub enable_cf_trace: bool,
    #[serde(default = "default_true")]
    pub enable_watchdog: bool,
    #[serde(default = "default_timeout")]
    pub request_timeout_sec: u64,
}

fn default_machine_id() -> String {
    detect_or_generate_machine_id()
}

fn default_hostname() -> String {
    detect_hostname()
}

fn detect_or_generate_machine_id() -> String {
    // 1. /etc/machine-id
    if let Ok(content) = fs::read_to_string("/etc/machine-id") {
        let s = content.trim();
        if !s.is_empty() {
            return s.to_string();
        }
    }
    // 2. /var/lib/dbus/machine-id
    if let Ok(content) = fs::read_to_string("/var/lib/dbus/machine-id") {
        let s = content.trim();
        if !s.is_empty() {
            return s.to_string();
        }
    }
    // 3. /sys/class/dmi/id/product_uuid
    if let Ok(content) = fs::read_to_string("/sys/class/dmi/id/product_uuid") {
        let s = content.trim();
        if !s.is_empty() {
            return s.to_string();
        }
    }
    // 4. 持久化缓存文件 .subskiff_mid
    let cache_file = Path::new(".subskiff_mid");
    if let Ok(content) = fs::read_to_string(cache_file) {
        let s = content.trim();
        if !s.is_empty() {
            return s.to_string();
        }
    }
    // 5. 随机生成 16 字节十六进制并保存
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let rand_id: String = (0..16)
        .map(|_| format!("{:02x}", rng.gen_range(0..=255u8)))
        .collect();
    let _ = fs::write(cache_file, &rand_id);
    rand_id
}

fn detect_hostname() -> String {
    if let Ok(content) = fs::read_to_string("/etc/hostname") {
        let s = content.trim();
        if !s.is_empty() {
            return s.to_string();
        }
    }
    if let Ok(content) = fs::read_to_string("/proc/sys/kernel/hostname") {
        let s = content.trim();
        if !s.is_empty() {
            return s.to_string();
        }
    }
    "vps_host".to_string()
}
fn default_mode() -> String {
    "cron".to_string()
}
fn default_min() -> u64 {
    300
}
fn default_max() -> u64 {
    300
}
fn default_node_path() -> String {
    "/root/node_info.txt".to_string()
}
fn default_true() -> bool {
    true
}
fn default_timeout() -> u64 {
    5
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct CpuStat {
    pub usage_percent: f32,
    pub cores: u32,
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct MemStat {
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct AgentIpIntel {
    #[serde(default)]
    pub ip: Option<String>,
    #[serde(default)]
    pub country_code: Option<String>,
    #[serde(default)]
    pub country: Option<String>,
    #[serde(default)]
    pub city: Option<String>,
    #[serde(default)]
    pub as_org: Option<String>,
    #[serde(default)]
    pub fraud_score: Option<u32>,
    #[serde(default)]
    pub is_residential: Option<bool>,
    #[serde(default)]
    pub is_broadcast: Option<bool>,
    #[serde(default)]
    pub colo: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Default, Clone, PartialEq)]
pub struct RealmEndpoint {
    pub listen_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AgentReportPayload {
    pub machine_id: String,
    pub hostname: Option<String>,
    pub token: String,
    pub mode: String,
    pub expected_interval_sec: u64,
    pub cpu: Option<CpuStat>,
    pub memory: Option<MemStat>,
    pub ip_intel: Option<AgentIpIntel>,
    pub nodes: Vec<String>,
    #[serde(default)]
    pub realm_endpoints: Vec<RealmEndpoint>,
    pub service_status: Option<String>,
}

/// 定位配置文件路径：优先支持 CLI 参数，其次检查程序所在同级目录与工作目录 (config.json 或 agent.json)
fn resolve_config_path(cli_path: Option<&str>) -> PathBuf {
    if let Some(p) = cli_path {
        return PathBuf::from(p);
    }

    if let Ok(exe_path) = env::current_exe() {
        if let Some(parent) = exe_path.parent() {
            let candidate_cfg = parent.join("config.json");
            if candidate_cfg.exists() {
                return candidate_cfg;
            }
            let candidate_agent = parent.join("agent.json");
            if candidate_agent.exists() {
                return candidate_agent;
            }
        }
    }

    // 降级为当前工作目录
    if Path::new("config.json").exists() {
        Path::new("config.json").to_path_buf()
    } else {
        Path::new("agent.json").to_path_buf()
    }
}

fn load_config(path: &Path) -> Result<AgentConfig, Box<dyn std::error::Error>> {
    let content = fs::read_to_string(path)?;
    let cfg: AgentConfig = serde_json::from_str(&content)?;
    Ok(cfg)
}

fn collect_cpu() -> CpuStat {
    let mut stat = CpuStat {
        usage_percent: 0.0,
        cores: 1,
    };
    if let Ok(cpuinfo) = fs::read_to_string("/proc/cpuinfo") {
        let cores = cpuinfo
            .lines()
            .filter(|l| l.starts_with("processor"))
            .count();
        if cores > 0 {
            stat.cores = cores as u32;
        }
    }
    if let Ok(loadavg) = fs::read_to_string("/proc/loadavg") {
        if let Some(first) = loadavg.split_whitespace().next() {
            if let Ok(one_min) = first.parse::<f32>() {
                stat.usage_percent = ((one_min / stat.cores.max(1) as f32) * 100.0).clamp(0.0, 100.0);
            }
        }
    }
    stat
}

fn collect_memory() -> MemStat {
    let mut stat = MemStat::default();
    if let Ok(meminfo) = fs::read_to_string("/proc/meminfo") {
        for line in meminfo.lines() {
            let mut parts = line.split_whitespace();
            if let (Some(k), Some(v)) = (parts.next(), parts.next()) {
                if let Ok(val_kb) = v.parse::<u64>() {
                    let bytes = val_kb * 1024;
                    if k == "MemTotal:" {
                        stat.total_bytes = bytes;
                    } else if k == "MemAvailable:" {
                        stat.available_bytes = bytes;
                    }
                }
            }
        }
        stat.used_bytes = stat.total_bytes.saturating_sub(stat.available_bytes);
    }
    stat
}

fn collect_nodes(path_str: &str) -> Vec<String> {
    let path = Path::new(path_str);
    if !path.exists() {
        return Vec::new();
    }
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    content
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| {
            l.starts_with("vless://")
                || l.starts_with("ss://")
                || l.starts_with("hysteria2://")
                || l.starts_with("tuic://")
                || l.starts_with("trojan://")
                || l.starts_with("anytls://")
        })
        .collect()
}

fn collect_realm_endpoints() -> Vec<RealmEndpoint> {
    let path = Path::new("/etc/realm/config.toml");
    if !path.exists() {
        return Vec::new();
    }
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let mut endpoints = Vec::new();
    let mut current_listen: Option<String> = None;
    let mut current_remote: Option<String> = None;

    for line in content.lines() {
        let line = line.trim();
        if line.starts_with("[[endpoints]]") {
            if let (Some(l), Some(r)) = (current_listen.take(), current_remote.take()) {
                if let Some(ep) = parse_realm_rule(&l, &r) {
                    endpoints.push(ep);
                }
            }
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let k = k.trim();
            let v = v.trim().trim_matches('"').trim_matches('\'');
            if k == "listen" {
                current_listen = Some(v.to_string());
            } else if k == "remote" {
                current_remote = Some(v.to_string());
            }
        }
    }
    if let (Some(l), Some(r)) = (current_listen, current_remote) {
        if let Some(ep) = parse_realm_rule(&l, &r) {
            endpoints.push(ep);
        }
    }
    endpoints
}

fn parse_realm_rule(listen: &str, remote: &str) -> Option<RealmEndpoint> {
    let l_port = if let Some((_, p)) = listen.rsplit_once(':') {
        p.parse::<u16>().ok()?
    } else {
        listen.parse::<u16>().ok()?
    };

    let (r_host, r_port_str) = remote.rsplit_once(':')?;
    let r_port = r_port_str.parse::<u16>().ok()?;
    let clean_host = r_host.trim_start_matches('[').trim_end_matches(']');

    Some(RealmEndpoint {
        listen_port: l_port,
        remote_host: clean_host.to_string(),
        remote_port: r_port,
    })
}

fn fetch_cf_trace(agent: &ureq::Agent) -> (Option<String>, Option<String>, Option<String>) {
    let resp = match agent.get("https://1.1.1.1/cdn-cgi/trace").call() {
        Ok(r) => r.into_string().unwrap_or_default(),
        Err(_) => return (None, None, None),
    };
    let mut ip = None;
    let mut loc = None;
    let mut colo = None;
    for line in resp.lines() {
        if let Some((k, v)) = line.split_once('=') {
            match k {
                "ip" => ip = Some(v.to_string()),
                "loc" => loc = Some(v.to_string()),
                "colo" => colo = Some(v.to_string()),
                _ => {}
            }
        }
    }
    (ip, loc, colo)
}

fn fetch_ippure(agent: &ureq::Agent) -> Option<AgentIpIntel> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct RawIpPure {
        ip: Option<String>,
        country_code: Option<String>,
        country: Option<String>,
        city: Option<String>,
        as_organization: Option<String>,
        fraud_score: Option<u32>,
        is_residential: Option<bool>,
        is_broadcast: Option<bool>,
    }
    let data: RawIpPure = agent
        .get("https://my.ippure.com/v1/info")
        .call()
        .ok()?
        .into_json()
        .ok()?;
    Some(AgentIpIntel {
        ip: data.ip,
        country_code: data.country_code,
        country: data.country,
        city: data.city,
        as_org: data.as_organization,
        fraud_score: data.fraud_score,
        is_residential: data.is_residential,
        is_broadcast: data.is_broadcast,
        colo: None,
    })
}

fn do_report(config: &AgentConfig, agent: &ureq::Agent, expected_interval: u64, is_once: bool) -> Result<(), String> {
    let mut ip_intel = AgentIpIntel::default();

    if config.enable_cf_trace {
        let (ip, loc, colo) = fetch_cf_trace(agent);
        ip_intel.ip = ip;
        ip_intel.country_code = loc;
        ip_intel.colo = colo;
    }

    if config.enable_ippure {
        if let Some(pure) = fetch_ippure(agent) {
            if pure.ip.is_some() {
                ip_intel.ip = pure.ip;
            }
            if pure.country_code.is_some() {
                ip_intel.country_code = pure.country_code;
            }
            ip_intel.country = pure.country;
            ip_intel.city = pure.city;
            ip_intel.as_org = pure.as_org;
            ip_intel.fraud_score = pure.fraud_score;
            ip_intel.is_residential = pure.is_residential;
        }
    }

    let nodes = collect_nodes(&config.node_info_path);
    let node_count = nodes.len();

    let actual_mid = if config.machine_id.is_empty() || config.machine_id == "vps_node" {
        detect_or_generate_machine_id()
    } else {
        config.machine_id.clone()
    };
    let actual_host = if config.hostname.is_empty() || config.hostname == "vps_node" {
        detect_hostname()
    } else {
        config.hostname.clone()
    };

    let payload = AgentReportPayload {
        machine_id: actual_mid,
        hostname: Some(actual_host),
        token: config.token.clone(),
        mode: config.mode.clone(),
        expected_interval_sec: expected_interval,
        cpu: Some(collect_cpu()),
        memory: Some(collect_memory()),
        ip_intel: Some(ip_intel),
        nodes,
        realm_endpoints: collect_realm_endpoints(),
        service_status: Some("running".to_string()),
    };

    let report_url = format!("{}/api/agent/report", config.server_url.trim_end_matches('/'));
    match agent
        .post(&report_url)
        .set("Content-Type", "application/json")
        .set("X-Agent-Token", &config.token)
        .send_json(&payload)
    {
        Ok(res) => {
            if is_once {
                println!(
                    "✅ 节点同步成功！[HTTP {}，同步节点数: {}]",
                    res.status(),
                    node_count
                );
            } else {
                println!(
                    "✅ 上报成功！[HTTP {}，节点数: {}，建议休眠: {}s]",
                    res.status(),
                    node_count,
                    expected_interval
                );
            }
            Ok(())
        }
        Err(e) => {
            let err_msg = format!("{}", e);
            eprintln!("❌ 上报失败: {}", err_msg);
            Err(err_msg)
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("轻舟端侧守护进程 (SubSkiff Daemon) - Rust 静态二进制版");
        println!("用法: subskiff-daemon [选项]");
        println!("选项:");
        println!("  -1, --once            仅执行一次同步上报并退出");
        println!("  -c, --config <PATH>   指定配置文件路径 (默认同级目录 config.json 或 daemon.json)");
        println!("  -h, --help            显示帮助信息");
        println!("  -v, --version         显示版本信息");
        return;
    }

    if args.iter().any(|a| a == "-v" || a == "--version") {
        println!("subskiff-daemon v{} (Rust static musl)", env!("CARGO_PKG_VERSION"));
        return;
    }

    let mut custom_config = None;
    let mut i = 1;
    while i < args.len() {
        if (args[i] == "-c" || args[i] == "--config") && i + 1 < args.len() {
            custom_config = Some(args[i + 1].as_str());
            i += 2;
        } else {
            i += 1;
        }
    }

    let config_path = resolve_config_path(custom_config);
    let once_mode = args.iter().any(|a| a == "--once" || a == "-1");

    if !config_path.exists() {
        eprintln!(
            "❌ 配置文件不存在: {}\n请在同级目录下创建 config.json 或 daemon.json，或通过 -c 指定配置。",
            config_path.display()
        );
        std::process::exit(1);
    }

    let config = match load_config(&config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("❌ 配置文件解析失败 ({}): {}", config_path.display(), e);
            std::process::exit(1);
        }
    };

    let timeout_sec = config.request_timeout_sec.max(2);
    let client = ureq::AgentBuilder::new()
        .timeout_read(Duration::from_secs(timeout_sec))
        .timeout_write(Duration::from_secs(timeout_sec))
        .build();

    let mut rng = rand::thread_rng();

    if once_mode || config.mode == "cron" {
        let interval = rng.gen_range(config.interval_min.min(config.interval_max)..=config.interval_max.max(config.interval_min));
        if let Err(_) = do_report(&config, &client, interval, once_mode) {
            std::process::exit(1);
        }
        return;
    }

    println!(
        ">>> 启动 SubSkiff Daemon 守护模式 v{} (机器: {}, 目标: {})...",
        env!("CARGO_PKG_VERSION"),
        config.machine_id,
        config.server_url
    );

    loop {
        let interval = rng.gen_range(config.interval_min.min(config.interval_max)..=config.interval_max.max(config.interval_min));
        let _ = do_report(&config, &client, interval, false);
        println!("💤 休眠 {} 秒后进行下一次上报...", interval);
        sleep(Duration::from_secs(interval));
    }
}
