#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    use serde::{Deserialize, Serialize};
    use std::{
        fs,
        io::Read,
        path::{Path, PathBuf},
        process::Command,
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        },
        thread,
        time::Duration,
    };
    use tauri::{
        menu::{Menu, MenuItem},
        tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
        webview::PageLoadEvent,
        Emitter, Manager, PhysicalPosition, Position, WebviewWindow,
    };

    #[derive(Debug, Default, Deserialize, Serialize)]
    struct StoredConfig {
        api_key: Option<String>,
        #[serde(default)]
        usage_token: Option<String>,
        refresh_interval_seconds: u64,
        #[serde(default)]
        auto_refresh_enabled: bool,
        autostart: bool,
    }

    #[derive(Debug, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct AppConfig {
        api_key_configured: bool,
        api_key_preview: Option<String>,
        usage_token_configured: bool,
        refresh_interval_seconds: u64,
        auto_refresh_enabled: bool,
        autostart: bool,
        config_path: String,
    }

    fn app_support_dir() -> Result<PathBuf, String> {
        let home = std::env::var_os("HOME").ok_or("HOME is not available")?;
        Ok(PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("DeepSeekMonitorMac"))
    }

    fn config_path() -> Result<PathBuf, String> {
        Ok(app_support_dir()?.join("config.json"))
    }

    fn read_stored_config() -> Result<StoredConfig, String> {
        let path = config_path()?;
        if !path.exists() {
            return Ok(StoredConfig {
                refresh_interval_seconds: 60,
                ..StoredConfig::default()
            });
        }

        let text = fs::read_to_string(&path).map_err(|error| error.to_string())?;
        let mut config: StoredConfig =
            serde_json::from_str(&text).map_err(|error| error.to_string())?;
        config.refresh_interval_seconds =
            normalize_refresh_interval_seconds(config.refresh_interval_seconds);
        Ok(config)
    }

    fn normalize_refresh_interval_seconds(value: u64) -> u64 {
        match value {
            60 | 300 | 1800 | 3600 => value,
            _ => 60,
        }
    }

    fn write_stored_config(config: &StoredConfig) -> Result<(), String> {
        let path = config_path()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }

        let text = serde_json::to_string_pretty(config).map_err(|error| error.to_string())?;
        fs::write(path, text).map_err(|error| error.to_string())
    }

    fn api_key_preview(api_key: &str) -> String {
        let chars: Vec<char> = api_key.chars().collect();
        if chars.len() <= 12 {
            return "已保存".to_string();
        }

        let start: String = chars.iter().take(7).collect();
        let end: String = chars
            .iter()
            .rev()
            .take(4)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        format!("{start}...{end}")
    }

    fn to_app_config(config: StoredConfig) -> Result<AppConfig, String> {
        let path = config_path()?;
        let api_key_preview = config
            .api_key
            .as_ref()
            .filter(|value| !value.is_empty())
            .map(|value| api_key_preview(value));

        let usage_token_configured = config
            .usage_token
            .as_ref()
            .map(|value| !value.is_empty())
            .unwrap_or(false);

        Ok(AppConfig {
            api_key_configured: api_key_preview.is_some(),
            api_key_preview,
            usage_token_configured,
            refresh_interval_seconds: config.refresh_interval_seconds,
            auto_refresh_enabled: config.auto_refresh_enabled,
            autostart: config.autostart,
            config_path: path.to_string_lossy().to_string(),
        })
    }

    // macOS 菜单栏在屏幕顶部，面板从右上角向下展开，贴着菜单栏图标下方。
    // work_area 已扣除菜单栏高度，position.y 即菜单栏下沿。
    fn position_near_tray(window: &WebviewWindow) -> tauri::Result<()> {
        let cursor = window.cursor_position()?;
        let monitor = window
            .monitor_from_point(cursor.x, cursor.y)?
            .or(window.current_monitor()?)
            .or(window.primary_monitor()?)
            .ok_or_else(|| tauri::Error::WindowNotFound)?;

        let work_area = monitor.work_area();
        let scale_factor = monitor.scale_factor();
        let size = window.outer_size()?;
        let margin = (8.0 * scale_factor).round() as i32;
        let width = size.width as i32;
        let right = work_area.position.x + work_area.size.width as i32;
        // 右上角：紧贴菜单栏下沿，距右边留一点边距，让面板大致落在菜单栏图标附近
        let x = right - width - margin;
        let y = work_area.position.y + margin;

        window.set_position(Position::Physical(PhysicalPosition::new(
            x.max(work_area.position.x),
            y.max(work_area.position.y),
        )))
    }

    fn show_main_window(window: &WebviewWindow) {
        let _ = position_near_tray(window);
        let _ = window.show();
        let _ = window.set_focus();
    }

    #[tauri::command]
    fn hide_main_window(window: WebviewWindow) -> Result<(), String> {
        window.hide().map_err(|error| error.to_string())
    }

    #[tauri::command]
    fn get_app_config() -> Result<AppConfig, String> {
        to_app_config(read_stored_config()?)
    }

    #[tauri::command]
    fn save_api_key(api_key: String) -> Result<AppConfig, String> {
        let value = api_key.trim().to_string();
        if value.is_empty() {
            return Err("API Key 不能为空".to_string());
        }

        let mut config = read_stored_config()?;
        config.api_key = Some(value);
        write_stored_config(&config)?;
        to_app_config(config)
    }

    #[tauri::command]
    fn clear_api_key() -> Result<AppConfig, String> {
        let mut config = read_stored_config()?;
        config.api_key = None;
        write_stored_config(&config)?;
        to_app_config(config)
    }

    #[tauri::command]
    fn save_refresh_interval(refresh_interval_seconds: u64) -> Result<AppConfig, String> {
        let mut config = read_stored_config()?;
        config.refresh_interval_seconds =
            normalize_refresh_interval_seconds(refresh_interval_seconds);
        write_stored_config(&config)?;
        to_app_config(config)
    }

    #[tauri::command]
    fn save_auto_refresh_enabled(auto_refresh_enabled: bool) -> Result<AppConfig, String> {
        let mut config = read_stored_config()?;
        config.auto_refresh_enabled = auto_refresh_enabled;
        write_stored_config(&config)?;
        to_app_config(config)
    }

    const LAUNCH_AGENT_LABEL: &str = "com.deepseek.monitor.mac";

    fn launch_agent_path() -> Result<PathBuf, String> {
        let home = std::env::var_os("HOME").ok_or("HOME is not available")?;
        Ok(PathBuf::from(home)
            .join("Library")
            .join("LaunchAgents")
            .join(format!("{LAUNCH_AGENT_LABEL}.plist")))
    }

    // macOS 开机自启：在 ~/Library/LaunchAgents 写入一个 plist，
    // RunAtLoad=true 让用户登录时由 launchd 拉起 .app。关闭时删除该 plist。
    fn apply_autostart(enabled: bool) -> Result<(), String> {
        let plist_path = launch_agent_path()?;

        if !enabled {
            if plist_path.exists() {
                fs::remove_file(&plist_path)
                    .map_err(|error| format!("关闭开机自启失败：{error}"))?;
            }
            return Ok(());
        }

        // current_exe 指向 .app/Contents/MacOS/<bin>，用 `open` 拉起整个 .app
        // 更符合 macOS 习惯（单实例、正常激活策略），从 MacOS 目录上溯三级得到 .app 路径。
        let exe = std::env::current_exe().map_err(|error| error.to_string())?;
        let app_bundle = exe
            .ancestors()
            .find(|p| p.extension().map(|e| e == "app").unwrap_or(false))
            .map(|p| p.to_path_buf());

        let program_args = match app_bundle {
            Some(app) => format!(
                "    <string>/usr/bin/open</string>\n    <string>{}</string>",
                app.to_string_lossy()
            ),
            // 开发态没有 .app 包，退化为直接拉起可执行文件
            None => format!("    <string>{}</string>", exe.to_string_lossy()),
        };

        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
{program_args}
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
"#
        );

        if let Some(parent) = plist_path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        fs::write(&plist_path, plist).map_err(|error| format!("写入开机自启失败：{error}"))?;
        // 让 launchd 立即加载，失败不致命（重新登录也会生效）
        let _ = Command::new("launchctl")
            .args(["load", "-w"])
            .arg(&plist_path)
            .status();
        Ok(())
    }

    #[tauri::command]
    fn save_autostart(autostart: bool) -> Result<AppConfig, String> {
        apply_autostart(autostart)?;
        let mut config = read_stored_config()?;
        config.autostart = autostart;
        write_stored_config(&config)?;
        to_app_config(config)
    }

    #[derive(Debug, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct BalanceResult {
        is_available: bool,
        currency: String,
        total_balance: String,
        granted_balance: String,
        topped_up_balance: String,
    }

    // 实时查询 DeepSeek 账户余额。DeepSeek 官方仅提供余额接口，无用量接口。
    #[tauri::command]
    async fn fetch_balance() -> Result<BalanceResult, String> {
        let config = read_stored_config()?;
        let api_key = config
            .api_key
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "未配置 API Key".to_string())?;

        let client = reqwest::Client::new();
        let response = client
            .get("https://api.deepseek.com/user/balance")
            .bearer_auth(&api_key)
            .timeout(std::time::Duration::from_secs(15))
            .send()
            .await
            .map_err(|error| format!("网络请求失败：{error}"))?;

        match response.status().as_u16() {
            200 => {}
            401 => return Err("API Key 无效或已过期".to_string()),
            429 => return Err("请求过于频繁，请稍后再试".to_string()),
            code if code >= 500 => return Err(format!("DeepSeek 服务器错误：{code}")),
            code => return Err(format!("请求失败：HTTP {code}")),
        }

        #[derive(Deserialize)]
        struct BalanceInfo {
            currency: String,
            total_balance: String,
            granted_balance: String,
            topped_up_balance: String,
        }
        #[derive(Deserialize)]
        struct BalanceResponse {
            is_available: bool,
            balance_infos: Vec<BalanceInfo>,
        }

        let data: BalanceResponse = response
            .json()
            .await
            .map_err(|error| format!("解析余额数据失败：{error}"))?;

        let info = data
            .balance_infos
            .into_iter()
            .next()
            .ok_or_else(|| "余额信息为空".to_string())?;

        Ok(BalanceResult {
            is_available: data.is_available,
            currency: info.currency,
            total_balance: info.total_balance,
            granted_balance: info.granted_balance,
            topped_up_balance: info.topped_up_balance,
        })
    }

    #[tauri::command]
    fn save_usage_token(usage_token: String) -> Result<AppConfig, String> {
        let value = usage_token.trim().to_string();
        if value.is_empty() {
            return Err("用量 Token 不能为空".to_string());
        }
        let mut config = read_stored_config()?;
        config.usage_token = Some(value);
        write_stored_config(&config)?;
        to_app_config(config)
    }

    #[tauri::command]
    fn clear_usage_token() -> Result<AppConfig, String> {
        let mut config = read_stored_config()?;
        config.usage_token = None;
        write_stored_config(&config)?;
        to_app_config(config)
    }

    const USAGE_TOKEN_TITLE_PREFIX: &str = "DSM_USAGE_TOKEN:";

    fn capture_usage_token(app: &tauri::AppHandle, token: String) -> Result<AppConfig, String> {
        let value = token.trim().to_string();
        if value.is_empty() {
            return Err("用量 Token 为空".to_string());
        }
        let mut config = read_stored_config()?;
        config.usage_token = Some(value);
        write_stored_config(&config)?;
        let app_config = to_app_config(config)?;

        // 标记本次同步已成功，避免 watcher 在窗口关闭后误发"结束等待"事件
        if let Some(flag) = app.try_state::<Arc<AtomicBool>>() {
            flag.store(true, Ordering::SeqCst);
        }

        if let Some(window) = app.get_webview_window("login-sync") {
            let _ = window.close();
        }

        let _ = app.emit("usage-token-captured", &app_config);

        Ok(app_config)
    }

    // 用 token 试调平台用量接口，验证它确实是有效的用量 token。
    async fn verify_usage_token(token: &str, month: u32, year: u32) -> Result<(), String> {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";
        let url =
            format!("https://platform.deepseek.com/api/v0/usage/amount?month={month}&year={year}");
        let resp = reqwest::Client::new()
            .get(&url)
            .bearer_auth(token)
            .header("x-app-version", "1.0.0")
            .header("Accept", "*/*")
            .header("User-Agent", ua)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(|error| format!("验证 token 失败：{error}"))?;
        if resp.status().as_u16() == 200 {
            Ok(())
        } else {
            Err(format!("token 无效：HTTP {}", resp.status().as_u16()))
        }
    }

    fn read_shared_text(path: &Path) -> Option<String> {
        // macOS 无强制文件锁，即便 WKWebView 正持有缓存文件也能并发读取。
        let mut file = fs::OpenOptions::new().read(true).open(path).ok()?;
        let metadata = file.metadata().ok()?;
        if metadata.len() == 0 || metadata.len() > 20 * 1024 * 1024 {
            return None;
        }
        let mut bytes = Vec::with_capacity(metadata.len() as usize);
        file.read_to_end(&mut bytes).ok()?;
        Some(String::from_utf8_lossy(&bytes).replace('\0', ""))
    }

    fn extract_user_api_token(text: &str) -> Option<String> {
        let mut search_from = 0;
        let marker = "\"token\":\"";
        while let Some(relative_index) = text[search_from..].find(marker) {
            let token_start = search_from + relative_index + marker.len();
            let token_end = token_start + text[token_start..].find('"')?;
            let token = &text[token_start..token_end];
            let context_end = (token_end + 1800).min(text.len());
            let context = &text[token_end..context_end];
            if token.len() > 20
                && context.contains("\"id_profile\"")
                && context.contains("\"feature_gates\"")
            {
                return Some(token.to_string());
            }
            search_from = token_end + 1;
        }
        None
    }

    // 递归扫一个目录下的文件，命中含 token 的缓存块即返回。限定深度与文件数量，
    // 避免极端情况下遍历过久。
    fn scan_dir_for_token(dir: &Path, depth: u32, budget: &mut u32) -> Option<String> {
        if depth == 0 || *budget == 0 {
            return None;
        }
        let entries = fs::read_dir(dir).ok()?;
        for entry in entries.flatten() {
            if *budget == 0 {
                break;
            }
            let path = entry.path();
            if path.is_dir() {
                if let Some(token) = scan_dir_for_token(&path, depth - 1, budget) {
                    return Some(token);
                }
                continue;
            }
            if !path.is_file() {
                continue;
            }
            *budget -= 1;
            if let Some(text) = read_shared_text(&path) {
                if let Some(token) = extract_user_api_token(&text) {
                    return Some(token);
                }
            }
        }
        None
    }

    // macOS 上 Tauri 用 WKWebView，HTTP 响应体落在沙盒外的
    // ~/Library/Caches/<bundle id>/ 与 ~/Library/WebKit/<bundle id>/ 下的
    // NetworkCache / fsCachedData 等子目录。遍历这两个根目录扫含 token 的缓存块。
    // 注意：这是辅助通道，主通道是登录窗口里注入 JS 抓 Authorization 头。
    fn find_webview_cached_usage_token() -> Option<String> {
        let home = std::env::var_os("HOME")?;
        let bundle_id = "com.deepseek.monitor.mac";
        let roots = [
            PathBuf::from(&home)
                .join("Library")
                .join("Caches")
                .join(bundle_id),
            PathBuf::from(&home)
                .join("Library")
                .join("WebKit")
                .join(bundle_id),
        ];
        for root in roots {
            if !root.exists() {
                continue;
            }
            let mut budget = 4000u32;
            if let Some(token) = scan_dir_for_token(&root, 8, &mut budget) {
                return Some(token);
            }
        }
        None
    }

    fn start_usage_title_watcher(app: tauri::AppHandle) {
        thread::spawn(move || {
            // 登录页加载并触发平台 API 请求需要时间，等待后再开始轮询
            thread::sleep(Duration::from_secs(3));
            for round in 0..1200u32 {
                // macOS 上用量接口响应多为 no-cache，几乎不会落盘到 WKWebView 缓存，
                // 缓存扫描命中率很低且需递归遍历大量文件，开销大。因此不每轮都扫，
                // 首轮扫一次、之后每 10 轮(约 15s)兜底扫一次；即时捕获主要靠下方
                // title hook(注入 JS 从 Authorization 头抓 token)。
                if round % 10 == 0 {
                    if let Some(token) = find_webview_cached_usage_token() {
                        let _ = capture_usage_token(&app, token);
                        return;
                    }
                }

                let Some(window) = app.get_webview_window("login-sync") else {
                    // 窗口已关闭：若不是因成功捕获而关闭，才通知前端结束等待
                    let captured = app
                        .try_state::<Arc<AtomicBool>>()
                        .map(|flag| flag.load(Ordering::SeqCst))
                        .unwrap_or(false);
                    if !captured {
                        let _ = app.emit("usage-sync-ended", ());
                    }
                    return;
                };

                if let Ok(title) = window.title() {
                    if let Some(rest) = title.strip_prefix(USAGE_TOKEN_TITLE_PREFIX) {
                        // 注入脚本写入的格式：{year}:{month}:{token}
                        let mut parts = rest.splitn(3, ':');
                        if let (Some(y), Some(m), Some(tok)) =
                            (parts.next(), parts.next(), parts.next())
                        {
                            if let (Ok(year), Ok(month)) = (y.parse::<u32>(), m.parse::<u32>()) {
                                let token = tok.to_string();
                                // 验证 token 真能调用用量接口，过滤登录中途的临时 token
                                let verified = tauri::async_runtime::block_on(
                                    verify_usage_token(&token, month, year),
                                );
                                if verified.is_ok() {
                                    let _ = capture_usage_token(&app, token);
                                    return;
                                }
                            }
                        }
                    }
                }

                thread::sleep(Duration::from_millis(1500));
            }
            // 30 分钟超时，若仍未成功则通知前端结束等待
            let captured = app
                .try_state::<Arc<AtomicBool>>()
                .map(|flag| flag.load(Ordering::SeqCst))
                .unwrap_or(false);
            if !captured {
                let _ = app.emit("usage-sync-ended", ());
            }
        });
    }

    // 在登录窗口注入，hook fetch / XMLHttpRequest，主动从平台 API 请求的
    // Authorization 头里抓 Bearer token。登录后页面自动调 API 即可即时捕获，
    // 不依赖磁盘缓存的延迟落盘(这是 macOS 上最可靠的主通道)。
    const USAGE_SYNC_POLL_JS: &str = r#"
    (function() {
      if (window.__dsm_token_hook__) return;
      window.__dsm_token_hook__ = true;
      var done = false;
      var pending = false;

      function deliver(token) {
        if (done) return;
        if (!token || typeof token !== 'string') return;
        token = token.trim();
        if (token.length < 20) return;
        var now = new Date();
        var y = now.getFullYear();
        var m = now.getMonth() + 1;
        // 主通道：写入 document.title，原生侧 window.title() 读取。
        // 外部网站窗口默认不注入 __TAURI__，此通道不依赖它，最可靠。
        try { document.title = 'DSM_USAGE_TOKEN:' + y + ':' + m + ':' + token; } catch (e) {}
        // 辅通道：若本窗口恰好可用 __TAURI__，直接上报更快
        try {
          if (!pending && window.__TAURI__ && window.__TAURI__.core) {
            pending = true;
            window.__TAURI__.core.invoke('usage_token_captured', {
              token: token, month: m, year: y
            }).then(function() { done = true; }).catch(function() { pending = false; });
          }
        } catch (e) {}
      }

      function fromAuth(value) {
        if (!value) return;
        var m = /Bearer\s+(\S+)/i.exec(String(value));
        if (m && m[1]) deliver(m[1]);
      }

      var origFetch = window.fetch;
      if (typeof origFetch === 'function') {
        window.fetch = function(input, init) {
          try {
            var headers = (init && init.headers) || (input && input.headers);
            if (headers) {
              if (typeof Headers !== 'undefined' && headers instanceof Headers) {
                fromAuth(headers.get('authorization'));
              } else if (Array.isArray(headers)) {
                for (var i = 0; i < headers.length; i++) {
                  if (headers[i] && String(headers[i][0]).toLowerCase() === 'authorization') {
                    fromAuth(headers[i][1]);
                  }
                }
              } else if (typeof headers === 'object') {
                for (var k in headers) {
                  if (k.toLowerCase() === 'authorization') fromAuth(headers[k]);
                }
              }
            }
          } catch (e) {}
          return origFetch.apply(this, arguments);
        };
      }

      var origSet = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        try {
          if (name && String(name).toLowerCase() === 'authorization') fromAuth(value);
        } catch (e) {}
        return origSet.apply(this, arguments);
      };
    })();
    "#;

    #[tauri::command]
    async fn start_usage_sync(app: tauri::AppHandle) -> Result<bool, String> {
        // 重置本次同步的成功标志
        if let Some(flag) = app.try_state::<Arc<AtomicBool>>() {
            flag.store(false, Ordering::SeqCst);
        }

        // 先扫一次缓存：登录完成后重复点击本命令，缓存落盘后即可命中
        if let Some(token) = find_webview_cached_usage_token() {
            capture_usage_token(&app, token)?;
            return Ok(true);
        }

        // 登录窗口已存在：刷新它，促使用量页重新请求接口、把响应写入缓存，
        // 用户随后再点一次本按钮即可命中。不重复弹新窗口、不死等。
        if app.get_webview_window("login-sync").is_some() {
            if let Some(window) = app.get_webview_window("login-sync") {
                let _ = window.eval("location.reload();");
            }
            return Ok(false);
        }

        let url = tauri::WebviewUrl::External("https://platform.deepseek.com".parse().unwrap());
        tauri::WebviewWindowBuilder::new(
            &app,
            "login-sync",
            url,
        )
        .title("DeepSeek 账号登录")
        .inner_size(480.0, 720.0)
        .min_inner_size(360.0, 480.0)
        .resizable(true)
        .center()
        .visible(true)
        .initialization_script(USAGE_SYNC_POLL_JS)
        .on_page_load(|window, payload| {
            if matches!(payload.event(), PageLoadEvent::Finished)
                && payload
                    .url()
                    .host_str()
                    .is_some_and(|host| host == "platform.deepseek.com")
            {
                // 双保险：万一 initialization_script 未注入，页面加载完再装一次 hook
                let _ = window.eval(USAGE_SYNC_POLL_JS);
            }
        })
        .build()
        .map_err(|error| format!("打开登录窗口失败：{error}"))?;
        start_usage_title_watcher(app);
        Ok(false)
    }

    #[tauri::command]
    async fn usage_token_captured(
        app: tauri::AppHandle,
        token: String,
        month: u32,
        year: u32,
    ) -> Result<AppConfig, String> {
        let value = token.trim().to_string();
        if value.is_empty() {
            return Err("用量 Token 为空".to_string());
        }
        // 先验证再保存：拦截到的 token 可能是登录中途的临时 token，
        // 只有能真正调用用量接口的才接受
        verify_usage_token(&value, month, year).await?;
        capture_usage_token(&app, value)
    }

    #[derive(Debug, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct UsageModelSummary {
        key: String,
        name: String,
        total_tokens: u64,
        request_count: u64,
        cache_hit_tokens: u64,
        cache_miss_tokens: u64,
        response_tokens: u64,
        cost: f64,
    }

    #[derive(Debug, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct UsageDaySummary {
        date: String,
        flash_tokens: u64,
        flash_cache_hit: u64,
        flash_cache_miss: u64,
        flash_response: u64,
        pro_tokens: u64,
        pro_cache_hit: u64,
        pro_cache_miss: u64,
        pro_response: u64,
        total_tokens: u64,
        total_cost: f64,
    }

    #[derive(Debug, Serialize)]
    #[serde(rename_all = "camelCase")]
    struct UsageResult {
        models: Vec<UsageModelSummary>,
        days: Vec<UsageDaySummary>,
        month_cost: f64,
    }

    // 通过 DeepSeek 平台内部接口拉取用量与费用（需网页登录 token，非官方 API Key）。
    #[tauri::command]
    async fn fetch_usage(month: u32, year: u32) -> Result<UsageResult, String> {
        let config = read_stored_config()?;
        let token = config
            .usage_token
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "未配置用量 Token".to_string())?;

        #[derive(Deserialize)]
        struct Entry {
            #[serde(rename = "type")]
            kind: String,
            amount: String,
        }
        #[derive(Deserialize)]
        struct ModelUsage {
            model: String,
            usage: Vec<Entry>,
        }
        #[derive(Deserialize)]
        struct DayUsage {
            date: String,
            data: Vec<ModelUsage>,
        }
        #[derive(Deserialize)]
        struct AmountBiz {
            total: Vec<ModelUsage>,
            days: Vec<DayUsage>,
        }
        #[derive(Deserialize)]
        struct AmountData {
            biz_data: AmountBiz,
        }
        #[derive(Deserialize)]
        struct AmountResp {
            data: AmountData,
        }
        #[derive(Deserialize)]
        struct CostBiz {
            total: Vec<ModelUsage>,
            days: Vec<DayUsage>,
        }
        #[derive(Deserialize)]
        struct CostData {
            biz_data: Vec<CostBiz>,
        }
        #[derive(Deserialize)]
        struct CostResp {
            data: CostData,
        }

        async fn get_json<T: serde::de::DeserializeOwned>(
            client: &reqwest::Client,
            url: &str,
            token: &str,
        ) -> Result<T, String> {
            let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
                      (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";
            let resp = client
                .get(url)
                .bearer_auth(token)
                .header("x-app-version", "1.0.0")
                .header("Accept", "*/*")
                .header("User-Agent", ua)
                .timeout(std::time::Duration::from_secs(15))
                .send()
                .await
                .map_err(|error| format!("用量请求失败：{error}"))?;
            match resp.status().as_u16() {
                200 => {}
                401 => return Err("用量 Token 无效或已过期，请重新获取".to_string()),
                429 => return Err("请求过于频繁，请稍后再试".to_string()),
                code => return Err(format!("用量接口错误：HTTP {code}")),
            }
            resp.json::<T>()
                .await
                .map_err(|error| format!("解析用量数据失败：{error}"))
        }

        fn token_breakdown(usage: &[Entry]) -> (u64, u64, u64, u64, u64) {
            // 返回 (总 token, 请求数, 缓存命中, 缓存未命中, 输出 token)
            let mut total = 0u64;
            let mut request = 0u64;
            let mut hit = 0u64;
            let mut miss = 0u64;
            let mut response = 0u64;
            for entry in usage {
                let value = entry.amount.parse::<f64>().unwrap_or(0.0).round() as u64;
                match entry.kind.as_str() {
                    "REQUEST" => request = value,
                    "PROMPT_CACHE_HIT_TOKEN" => {
                        hit = value;
                        total += value;
                    }
                    "PROMPT_CACHE_MISS_TOKEN" => {
                        miss = value;
                        total += value;
                    }
                    "RESPONSE_TOKEN" => {
                        response = value;
                        total += value;
                    }
                    "PROMPT_TOKEN" => total += value,
                    _ => {}
                }
            }
            (total, request, hit, miss, response)
        }

        fn cost_sum(usage: &[Entry]) -> f64 {
            usage
                .iter()
                .filter(|entry| entry.kind != "REQUEST")
                .map(|entry| entry.amount.parse::<f64>().unwrap_or(0.0))
                .sum()
        }

        let client = reqwest::Client::new();
        let amount_url =
            format!("https://platform.deepseek.com/api/v0/usage/amount?month={month}&year={year}");
        let cost_url =
            format!("https://platform.deepseek.com/api/v0/usage/cost?month={month}&year={year}");

        let amount: AmountResp = get_json(&client, &amount_url, &token).await?;
        let cost: CostResp = get_json(&client, &cost_url, &token).await?;

        let cost_total = cost.data.biz_data.first();
        let cost_for_model = |model: &str| -> f64 {
            cost_total
                .and_then(|item| item.total.iter().find(|m| m.model == model))
                .map(|m| cost_sum(&m.usage))
                .unwrap_or(0.0)
        };

        let mut models = Vec::new();
        for model_usage in &amount.data.biz_data.total {
            let label = match model_usage.model.as_str() {
                "deepseek-v4-flash" => Some(("flash", "V4 Flash")),
                "deepseek-v4-pro" => Some(("pro", "V4 Pro")),
                _ => None,
            };
            if let Some((key, name)) = label {
                let (total, request, hit, miss, response) = token_breakdown(&model_usage.usage);
                models.push(UsageModelSummary {
                    key: key.to_string(),
                    name: name.to_string(),
                    total_tokens: total,
                    request_count: request,
                    cache_hit_tokens: hit,
                    cache_miss_tokens: miss,
                    response_tokens: response,
                    cost: cost_for_model(&model_usage.model),
                });
            }
        }

        let mut cost_by_date: std::collections::HashMap<String, f64> =
            std::collections::HashMap::new();
        if let Some(item) = cost_total {
            for day in &item.days {
                let day_cost: f64 = day.data.iter().map(|m| cost_sum(&m.usage)).sum();
                cost_by_date.insert(day.date.clone(), day_cost);
            }
        }

        let mut days = Vec::new();
        for day in &amount.data.biz_data.days {
            let mut flash = 0u64;
            let mut flash_hit = 0u64;
            let mut flash_miss = 0u64;
            let mut flash_resp = 0u64;
            let mut pro = 0u64;
            let mut pro_hit = 0u64;
            let mut pro_miss = 0u64;
            let mut pro_resp = 0u64;
            let mut total = 0u64;
            for model_usage in &day.data {
                let (tokens, _, hit, miss, response) = token_breakdown(&model_usage.usage);
                total += tokens;
                match model_usage.model.as_str() {
                    "deepseek-v4-flash" => {
                        flash += tokens;
                        flash_hit += hit;
                        flash_miss += miss;
                        flash_resp += response;
                    }
                    "deepseek-v4-pro" => {
                        pro += tokens;
                        pro_hit += hit;
                        pro_miss += miss;
                        pro_resp += response;
                    }
                    _ => {}
                }
            }
            days.push(UsageDaySummary {
                date: day.date.clone(),
                flash_tokens: flash,
                flash_cache_hit: flash_hit,
                flash_cache_miss: flash_miss,
                flash_response: flash_resp,
                pro_tokens: pro,
                pro_cache_hit: pro_hit,
                pro_cache_miss: pro_miss,
                pro_response: pro_resp,
                total_tokens: total,
                total_cost: cost_by_date.get(&day.date).copied().unwrap_or(0.0),
            });
        }

        let month_cost: f64 = cost_total
            .map(|item| item.total.iter().map(|m| cost_sum(&m.usage)).sum())
            .unwrap_or(0.0);

        Ok(UsageResult {
            models,
            days,
            month_cost,
        })
    }

    tauri::Builder::default()
        // 单实例守卫：必须作为第一个注册的插件。
        // 程序已运行时再次启动 exe，第二个进程不会新开窗口，
        // 而是触发此回调把已有主窗口显示并聚焦，随后第二个进程自行退出。
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                show_main_window(&window);
            }
        }))
        .manage(Arc::new(AtomicBool::new(false)))
        .invoke_handler(tauri::generate_handler![
            hide_main_window,
            get_app_config,
            save_api_key,
            clear_api_key,
            save_refresh_interval,
            save_auto_refresh_enabled,
            save_autostart,
            fetch_balance,
            save_usage_token,
            clear_usage_token,
            fetch_usage,
            start_usage_sync,
            usage_token_captured
        ])
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            // 菜单栏应用：Accessory 策略让 App 不出现在 Dock、不抢主菜单栏，
            // 只通过状态栏托盘图标交互。
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let show_item = MenuItem::with_id(app, "show", "显示主面板", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let tray_menu = Menu::with_items(app, &[&show_item, &quit_item])?;

            let mut tray_builder = TrayIconBuilder::new()
                .menu(&tray_menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            show_main_window(&window);
                        }
                    }
                    "quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    // 仅在左键“抬起”时切换；否则按下+抬起各触发一次，窗口会闪现后立即隐藏
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            let is_visible = window.is_visible().unwrap_or(false);
                            if is_visible {
                                let _ = window.hide();
                            } else {
                                show_main_window(&window);
                            }
                        }
                    }
                });

            if let Some(icon) = app.default_window_icon() {
                tray_builder = tray_builder.icon(icon.clone());
            }

            tray_builder.build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
